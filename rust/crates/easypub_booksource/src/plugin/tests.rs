use super::*;
use std::time::Instant;

fn wait_until(mut ready: impl FnMut() -> bool) {
    let start = Instant::now();
    while !ready() {
        assert!(start.elapsed() < Duration::from_secs(6), "等待插件状态超时");
        std::thread::sleep(Duration::from_millis(15));
    }
}

#[test]
fn v88_storage_stream_queue_and_legacy_rebuild() {
    let slow = Arc::new(AtomicBool::new(true));
    let slow_page = slow.clone();
    let (base, _) = crate::tests::serve(move |req| {
        if req.path == "/slow-search"
            || (req.path == "/c" && slow_page.swap(false, Ordering::Relaxed))
        {
            std::thread::sleep(Duration::from_secs(3));
        }
        let body = match req.path.as_str() {
            "/s" | "/slow-search" => "<li><a href='/b'>测试书</a><span>作者甲</span></li>",
            "/b" => "<a id='toc' href='/toc'>目录</a>",
            "/toc" => "<li><a href='/c'>第1章 起点</a></li>",
            "/empty" => "<div>没有正文容器</div>",
            "/alt-toc" => "<li><a href='/good'>第1章 起点</a></li>",
            "/ambiguous-toc" => {
                "<li><a href='/good'>第1章 起点</a></li><li><a href='/other'>第1章 起点</a></li>"
            }
            "/good" => {
                "<div id='c'>第1章 起点<br>这是一段用于确认换源补全的自拟正文，章节身份唯一时才能填入缺失缓存。</div>"
            }
            _ => "<div id='c'>第1章 起点<br>在路上，他四下看了看。</div>",
        };
        let body = if ["/c", "/good"].contains(&req.path.as_str()) {
            body.replace(
                "</div>",
                &format!(
                    "<br>{}</div>",
                    "这段自拟的补充文字用于验证正常章节，不属于短正文或限流提示。".repeat(12)
                ),
            )
        } else {
            body.to_owned()
        };
        crate::tests::html(&body)
    });
    let root = std::env::temp_dir().join(format!("ep-v88-plugin-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let rules = json!({"bookSourceUrl":base,"bookSourceName":"夹具","enabled":true,"searchUrl":"/s",
        "header":"{\"Cookie\":\"sid=fake-test-secret\",\"Authorization\":\"fake-auth\"}",
        "ruleSearch":{"bookList":"li","name":"a@text","author":"span@text","bookUrl":"a@href"},
        "ruleBookInfo":{"tocUrl":"#toc@href"},"ruleToc":{"chapterList":"li","chapterName":"a@text","chapterUrl":"a@href"},"ruleContent":{"content":"#c@html"}});
    // V87 的扁平 sources.json 无管理字段，新版可直接读取。
    let mut legacy = rules.clone();
    legacy["header"] = json!("");
    std::fs::write(root.join("sources.json"), json!([legacy]).to_string()).unwrap();
    STATE
        .set(Mutex::new(State {
            data: root.clone(),
            max_books: 1,
            ..Default::default()
        }))
        .ok()
        .unwrap();
    load();
    assert_eq!(
        handle("sources.list", &json!({}))
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    handle(
        "__import_body",
        &json!({"text":json!([rules]).to_string(),"file":"甲.json"}),
    )
    .unwrap();
    let mut second = rules.clone();
    second["lastUpdateTime"] = json!(2);
    handle(
        "__import_body",
        &json!({"text":json!([second]).to_string(),"file":"乙.json"}),
    )
    .unwrap();
    let listed = handle("sources.list", &json!({})).unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 2);
    assert_eq!(listed[0]["duplicate"], true);
    let saved = std::fs::read_to_string(root.join("sources.json")).unwrap();
    assert!(!saved.contains("fake-test-secret") && !saved.contains("fake-auth"));
    handle("sources.pin", &json!({"ids":[listed[0]["id"]]})).unwrap();
    handle("sources.rate", &json!({"id":listed[0]["id"],"rating":2})).unwrap();
    let updated = handle("sources.list", &json!({})).unwrap();
    assert_eq!(updated[0]["pinned"], true);
    assert_eq!(updated[0]["rating"], 2);
    handle(
        "sources.pin",
        &json!({"ids":[listed[0]["id"]],"position":"bottom"}),
    )
    .unwrap();
    assert_eq!(
        handle("sources.list", &json!({})).unwrap()[0]["pinned"],
        false
    );
    handle(
        "sources.order",
        &json!({"ids":[listed[1]["id"],listed[0]["id"]]}),
    )
    .unwrap();
    handle(
        "filters.save",
        &json!({"name":"常用","filter":{"tags":["JS","可用"]}}),
    )
    .unwrap();
    assert_eq!(
        handle("filters.list", &json!({})).unwrap()[0]["filter"]["tags"][1],
        "可用"
    );
    let mut slow_source = rules.clone();
    slow_source["bookSourceUrl"] = json!(format!("{base}#slow"));
    slow_source["searchUrl"] = json!("/slow-search");
    handle(
        "__import_body",
        &json!({"text":json!([slow_source]).to_string(),"file":"慢源.json"}),
    )
    .unwrap();
    let search = std::thread::spawn(|| {
        handle(
            "search",
            &json!({"key":"测试书","stream":true,"searchId":"test-stream"}),
        )
    });
    wait_until(|| {
        TEST_EVENTS
            .lock()
            .unwrap()
            .iter()
            .any(|v| v["event"] == "search.result" && !v["items"].as_array().unwrap().is_empty())
    });
    assert!(!search.is_finished(), "快源结果应先于慢源完成被推送");
    handle("search.cancel", &json!({"searchId":"test-stream"})).unwrap();
    assert_eq!(search.join().unwrap().unwrap()["cancelled"], true);
    handle("sources.ping", &json!({"ids":[base]})).unwrap();
    assert!(
        handle("sources.list", &json!({})).unwrap()[0]["health"]["ms"]
            .as_array()
            .unwrap()
            .len()
            >= 2
    );
    let book = Book {
        name: "测试书".into(),
        author: "作者甲".into(),
        origin: base.clone(),
        book_url: format!("{base}/b"),
        toc_url: format!("{base}/toc"),
        ..Default::default()
    };
    let options = Options {
        folder: root.join("downloads"),
        ..Default::default()
    };
    let first = handle(
        "queue.add",
        &json!({"sourceId":base,"book":book,"options":options}),
    )
    .unwrap();
    let id = first["taskId"].as_str().unwrap();
    wait_until(|| !slow.load(Ordering::Relaxed));
    let at = Instant::now();
    handle("queue.pause", &json!({"taskId":id})).unwrap();
    wait_until(|| state().tasks.is_empty());
    assert!(at.elapsed() < Duration::from_secs(2));
    assert_eq!(
        handle("queue.list", &json!({})).unwrap()["tasks"][0]["status"],
        "paused"
    );
    // 首页连通与完整校验是两个结果，测速不能清除正文失败和失败计数。
    let mut empty_source = rules.clone();
    let check_id = format!("{base}#empty-check");
    empty_source["bookSourceUrl"] = json!(check_id);
    empty_source["ruleContent"]["content"] = json!("#missing@html");
    handle(
        "__import_body",
        &json!({"text":json!([empty_source]).to_string(),"file":"校验夹具"}),
    )
    .unwrap();
    handle("sources.check", &json!({"ids":[check_id]})).unwrap();
    let before = handle("sources.list", &json!({})).unwrap();
    let before = before
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == check_id)
        .unwrap();
    assert_eq!(before["check"]["ok"], false);
    assert_eq!(before["check"]["stage"], "content");
    // V103：显式单源交互、独立校验记录、重叠拒绝及取消。
    for params in [
        json!({"interactive":true}),
        json!({"interactive":true,"ids":[base,check_id],"checkId":"bad"}),
        json!({"interactive":true,"ids":["missing"],"checkId":"bad"}),
        json!({"interactive":true,"ids":[base]}),
    ] {
        assert!(handle("sources.check", &params).is_err());
    }
    let first = handle(
        "sources.check",
        &json!({"ids":[base],"interactive":true,"checkId":"fixture-success"}),
    )
    .unwrap();
    assert_eq!(first["ok"], 1);
    assert_eq!(first["cancelled"], false);
    assert!(
        TEST_EVENTS
            .lock()
            .unwrap()
            .iter()
            .any(|e| e["event"] == "check.result"
                && e["checkId"] == "fixture-success"
                && e["interactive"] == true
                && e["ok"] == true)
    );
    let mut looping: BookSource = serde_json::from_value(rules.clone()).unwrap();
    looping.book_source_url = format!("{base}#cancel-check");
    looping.main_js = "java.toast('ready'); while(true){}".into();
    let loop_id = looping.id().to_owned();
    state().sources.push((looping, true));
    let entered = Arc::new(AtomicBool::new(false));
    let ready = entered.clone();
    *runtime(&loop_id)
        .unwrap()
        .services
        .interaction
        .lock()
        .unwrap() = Some(Arc::new(move |_, _| {
        assert!(crate::control::current().interactive);
        ready.store(true, Ordering::Relaxed);
        Ok(true.into())
    }));
    let target = loop_id.clone();
    let running = std::thread::spawn(move || {
        handle(
            "sources.check",
            &json!({"ids":[target],"interactive":true,"checkId":"fixture-cancel"}),
        )
    });
    wait_until(|| entered.load(Ordering::Relaxed));
    assert!(
        handle(
            "sources.check",
            &json!({"ids":[loop_id],"checkId":"overlap"})
        )
        .is_err()
    );
    assert!(
        handle(
            "sources.check",
            &json!({"ids":[base],"checkId":"fixture-cancel"})
        )
        .is_err()
    );
    assert_eq!(
        handle("sources.check.cancel", &json!({"checkId":"fixture-cancel"})).unwrap()["cancelled"],
        true
    );
    let cancelled = running.join().unwrap().unwrap();
    assert_eq!(cancelled["cancelled"], true);
    assert_eq!(cancelled["ok"], 0);
    let cancelled_record = state()
        .sources
        .iter()
        .find(|(s, _)| s.id() == loop_id)
        .unwrap()
        .0
        .meta
        .check
        .clone()
        .unwrap();
    assert_eq!(cancelled_record["checkId"], "fixture-cancel");
    assert_eq!(cancelled_record["cancelled"], true);
    assert_eq!(cancelled_record["error"], "已取消");
    assert_eq!(
        handle("sources.check.cancel", &json!({"checkId":"fixture-cancel"})).unwrap()["cancelled"],
        false
    );
    handle(
        "sources.check",
        &json!({"ids":[check_id],"interactive":true,"checkId":"fixture-recheck"}),
    )
    .unwrap();
    assert_eq!(
        state()
            .sources
            .iter()
            .find(|(s, _)| s.id() == check_id)
            .unwrap()
            .0
            .meta
            .check
            .as_ref()
            .unwrap()["checkId"],
        "fixture-recheck"
    );
    // 后续原测速断言以新一轮失败记录为基线，保留先前记录对象不改写。
    assert_ne!(before["check"]["checkId"], "fixture-recheck");
    let before = handle("sources.list", &json!({})).unwrap();
    let before = before
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == check_id)
        .unwrap();
    handle("sources.ping", &json!({"ids":[check_id]})).unwrap();
    let after = handle("sources.list", &json!({})).unwrap();
    let after = after
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == check_id)
        .unwrap();
    assert_eq!(after["check"], before["check"]);
    assert_eq!(
        after["health"]["failStreak"],
        before["health"]["failStreak"]
    );
    assert_eq!(after["ping"]["ok"], true);
    queue::shutdown();
    state().queue.clear();
    queue::load();
    assert_eq!(state().queue[0].status, "paused", "重开保留暂停与原始请求");
    handle("queue.resume", &json!({"taskId":id})).unwrap();
    wait_until(|| state().queue[0].status == "done");
    let records = load_library();
    assert_eq!(records.len(), 1);
    let path = PathBuf::from(records[0]["path"].as_str().unwrap());
    assert!(path.is_file());
    // 单独清除下载记录（LIB-223）：只删这一条记录，文件与书架记录不动。
    assert!(handle("queue.remove", &json!({"taskId":"no-such-task"})).is_err());
    handle("queue.remove", &json!({"taskId":id})).unwrap();
    assert!(state().queue.iter().all(|t| t.id != id));
    assert!(path.is_file());
    assert_eq!(load_library().len(), 1);
    let cache = download::cache_dir(&options.folder, &book);
    let dirty = "第1章 起点\n在路上，他四下\n第1章 起点\n看了看。";
    std::fs::write(cache.join("00000.txt"), dirty).unwrap();
    let old_txt = "测试书\n作者：作者甲\n\n\n第1章 起点\n\n　　在路上，他四下\n　　第1章 起点\n　　看了看。\n";
    std::fs::write(&path, old_txt).unwrap();
    let mut old_records = records.clone();
    old_records[0].as_object_mut().unwrap().remove("toc");
    std::fs::remove_file(cache.join("toc.json")).unwrap();
    library::save_library(&old_records).unwrap();
    let rebuilt = handle("library.rebuild", &json!({"key":records[0]["key"]})).unwrap();
    let output = std::fs::read_to_string(&path).unwrap();
    assert_eq!(output.matches("第1章 起点").count(), 1);
    assert!(output.contains("在路上，他四下看了看。"));
    assert_eq!(
        std::fs::read_to_string(path.with_extension("bak.txt")).unwrap(),
        old_txt
    );
    assert_eq!(rebuilt["quality"]["duplicateHeadings"], 0);
    handle("sources.dedupe", &json!({"action":"disable"})).unwrap();
    load();
    let listed = handle("sources.list", &json!({})).unwrap();
    assert_eq!(listed[0]["enabled"], false);
    assert_eq!(listed[1]["enabled"], true);
    handle("sources.dedupe", &json!({"action":"delete"})).unwrap();
    assert_eq!(runtime(&base).unwrap().source.meta.id, listed[1]["id"]);
    let alt_id = format!("{base}#alternative");
    let mut alt_rules = rules.clone();
    alt_rules["bookSourceUrl"] = json!(alt_id);
    handle(
        "__import_body",
        &json!({"text":json!([alt_rules]).to_string(),"file":"替代源.json"}),
    )
    .unwrap();
    for (page, expected_failures) in [("alt-toc", 0), ("ambiguous-toc", 1)] {
        let mut primary = book.clone();
        primary.book_url = format!("{base}/recovery-{page}");
        let mut alternate = book.clone();
        alternate.origin = alt_id.clone();
        alternate.toc_url = format!("{base}/{page}");
        let options = Options {
            folder: root.join("recovery"),
            retries: 0,
            ..Default::default()
        };
        let task = handle("queue.add", &json!({"sourceId":base,"book":primary,"options":options,
            "toc":[Chapter{title:"第1章 起点".into(),url:format!("{base}/empty"),..Default::default()}],
            "alternates":[{"sourceId":alt_id,"book":alternate}]})).unwrap();
        wait_until(|| {
            state().queue.iter().any(|t| {
                t.id == task["taskId"]
                    && t.status
                        == if expected_failures == 0 {
                            "done"
                        } else {
                            "failed"
                        }
            })
        });
        let st = state();
        let result = st
            .queue
            .iter()
            .find(|t| t.id == task["taskId"])
            .unwrap()
            .result
            .as_ref()
            .unwrap();
        assert_eq!(
            result["outcome"]["failures"].as_array().unwrap().len(),
            expected_failures,
            "重复标题和章号不猜测对应关系"
        );
    }
    import_options_keep_user_fields_and_place_new_sources(&base, &root);
    // 检查更新可并发；结果仍按书写回记录。
    let checked = handle("library.check", &json!({"concurrency":2})).unwrap();
    assert!(
        checked["records"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["checkedAt"].is_number())
    );
    // 书架定时检查：默认关闭；到期才检查并发事件，不自动下载。
    assert_eq!(
        handle("library.autoCheck.get", &json!({})).unwrap()["hours"],
        0
    );
    library::auto_due();
    assert!(
        !TEST_EVENTS
            .lock()
            .unwrap()
            .iter()
            .any(|e| e["event"] == "library.autoChecked")
    );
    assert!(handle("library.autoCheck.set", &json!({"hours":1000})).is_err());
    handle("library.autoCheck.set", &json!({"hours":6,"concurrency":2})).unwrap();
    library::auto_due();
    assert!(
        TEST_EVENTS
            .lock()
            .unwrap()
            .iter()
            .any(|e| e["event"] == "library.autoChecked")
    );
    let last = handle("library.autoCheck.get", &json!({})).unwrap()["lastChecked"]
        .as_u64()
        .unwrap();
    assert!(last > 0);
    // 未到期不重复检查。
    TEST_EVENTS.lock().unwrap().clear();
    library::auto_due();
    assert!(TEST_EVENTS.lock().unwrap().is_empty());
    queue::shutdown();
    fqnovel::tests::subscription_fixture();
    explore_refresh_rejects_stale_results();
    interactions::tests::reply_is_scoped_single_use_and_timeout_cleans_up();
    login_buttons_run_source_action();
    std::fs::remove_dir_all(root).unwrap();
}

fn explore_refresh_rejects_stale_results() {
    let entered = Arc::new(AtomicBool::new(false));
    let release = Arc::new(AtomicBool::new(false));
    let waiting = entered.clone();
    let released = release.clone();
    let (base, _) = crate::tests::serve(move |_| {
        waiting.store(true, Ordering::SeqCst);
        let until = Instant::now() + Duration::from_secs(5);
        while !released.load(Ordering::SeqCst) && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(5));
        }
        crate::tests::html("<li><a href='/b'>发现夹具</a></li>")
    });
    let source: BookSource = serde_json::from_value(json!({"bookSourceUrl":base,"ruleExplore":{"bookList":"li","name":"a@text","bookUrl":"a@href"}})).unwrap();
    state().sources.push((source, true));
    let rt = runtime(&base).unwrap();
    // 旧界面默认只接首批三种交互；新能力必须显式协商。
    handle(
        "source.interaction.enable",
        &json!({"id":base,"enabled":true}),
    )
    .unwrap();
    for kind in ["book_search", "login_open"] {
        assert!(
            rt.services
                .request(kind, json!({}))
                .unwrap_err()
                .contains("尚未连接")
        );
    }
    handle(
        "source.interaction.enable",
        &json!({"id":base,"enabled":true,"capabilities":["book_search","login_open"]}),
    )
    .unwrap();
    assert!(
        rt.services
            .request("notice", json!({"text":"fixture"}))
            .is_err()
    );
    assert!(
        handle(
            "source.interaction.enable",
            &json!({"id":base,"enabled":true,"capabilities":["unknown"]})
        )
        .is_err()
    );
    *rt.services.interaction.lock().unwrap() = Some(Arc::new(|kind, _| {
        assert_eq!(kind, "explore_refresh");
        Ok(json!(true))
    }));
    let target = base.clone();
    let worker = std::thread::spawn(move || {
        handle(
            "source.explore",
            &json!({"id":target,"url":target,"page":1}),
        )
    });
    wait_until(|| entered.load(Ordering::SeqCst));
    assert!(rt.services.action("explore_refresh", json!({})).unwrap());
    release.store(true, Ordering::SeqCst);
    let stale = worker.join().unwrap().unwrap();
    assert_eq!(stale["stale"], true);
    assert_eq!(stale["books"], json!([]));
    assert_eq!(stale["current_revision"], 1);
    let fresh = handle("source.explore", &json!({"id":base,"url":base,"page":1})).unwrap();
    assert_eq!(fresh["stale"], false);
    assert_eq!(fresh["books"][0]["name"], "发现夹具");
    assert_eq!(
        handle("source.exploreRevision", &json!({"id":base})).unwrap()["revision"],
        1
    );
    assert!(handle("source.explore", &json!({"id":base,"url":base,"page":0})).is_err());
    handle(
        "source.interaction.enable",
        &json!({"id":base,"enabled":false}),
    )
    .unwrap();
}

/// V91：导入偏好（名称 / 分组覆盖、新书源位置）对文件导入生效，并持久化。
fn import_options_keep_user_fields_and_place_new_sources(base: &str, root: &std::path::Path) {
    let defaults = handle("sources.importOptions.get", &json!({})).unwrap();
    assert_eq!(
        defaults,
        json!({"position":"bottom","overrideName":true,"overrideGroup":false})
    );
    let rule = |url: &str, name: &str, group: &str| {
        json!({"bookSourceUrl":url,"bookSourceName":name,"bookSourceGroup":group,"searchUrl":"/s",
            "ruleSearch":{"bookList":"li","name":"a@text","bookUrl":"a@href"},
            "ruleToc":{"chapterList":"li","chapterName":"a@text","chapterUrl":"a@href"},
            "ruleContent":{"content":"#c@html"}})
    };
    let import = |items: Vec<Value>, file: &str| {
        handle(
            "__import_body",
            &json!({"text":Value::Array(items).to_string(),"file":file}),
        )
        .unwrap()
    };
    let find = |url: &str| {
        handle("sources.list", &json!({}))
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["url"] == url)
            .cloned()
            .unwrap()
    };
    let a = format!("{base}/imp-a");
    import(vec![rule(&a, "原名", "文件组")], "丙.json");
    handle("sources.setGroup", &json!({"ids":[a],"group":"我的分组"})).unwrap();
    // 默认：名称随新文件，分组保留用户整理的。
    import(vec![rule(&a, "新名", "新文件组")], "丙.json");
    assert_eq!(find(&a)["name"], "新名");
    assert_eq!(find(&a)["group"], "我的分组");
    // 反过来：分组随新文件，名称保留。
    handle(
        "sources.importOptions.set",
        &json!({"options":{"position":"top","overrideName":false,"overrideGroup":true}}),
    )
    .unwrap();
    import(vec![rule(&a, "再改名", "第三组")], "丙.json");
    assert_eq!(find(&a)["name"], "新名");
    assert_eq!(find(&a)["group"], "第三组");
    // 新书源放最前，彼此保持文件顺序。
    let (b, c) = (format!("{base}/imp-b"), format!("{base}/imp-c"));
    let others_min = handle("sources.list", &json!({}))
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["customOrder"].as_i64().unwrap())
        .min()
        .unwrap();
    import(vec![rule(&b, "乙", ""), rule(&c, "丙", "")], "丁.json");
    let (ob, oc) = (
        find(&b)["customOrder"].as_i64().unwrap(),
        find(&c)["customOrder"].as_i64().unwrap(),
    );
    assert!(ob < oc && oc < others_min, "{ob} {oc} {others_min}");
    // 放最后。
    handle(
        "sources.importOptions.set",
        &json!({"options":{"position":"bottom","overrideName":true,"overrideGroup":false}}),
    )
    .unwrap();
    let d = format!("{base}/imp-d");
    import(vec![rule(&d, "戊", "")], "戊.json");
    let max_others = handle("sources.list", &json!({}))
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["url"] != d.as_str())
        .map(|s| s["customOrder"].as_i64().unwrap())
        .max()
        .unwrap();
    assert!(find(&d)["customOrder"].as_i64().unwrap() > max_others);
    // 偏好写入数据目录，重开插件后仍在；非法位置被拒绝。
    assert!(
        handle(
            "sources.importOptions.set",
            &json!({"options":{"position":"middle"}})
        )
        .is_err()
    );
    sources::load_import_options(root);
    assert_eq!(
        handle("sources.importOptions.get", &json!({})).unwrap()["position"],
        "bottom"
    );
}

/// 登录界面按钮（阅读 loginUi 的 button）：按序号执行书源自带的 action，可调用 loginUrl 里的函数；不接受任意脚本。
fn login_buttons_run_source_action() {
    let id = "https://login-buttons.invalid";
    let ui = json!([
        {"name":"切换模式","type":"button","action":"fqCycle()"},
        {"name":"账号","type":"text"}
    ])
    .to_string();
    let source: BookSource = serde_json::from_value(json!({
        "bookSourceUrl": id,
        "loginUrl": "function fqCycle(){var n=Number(String(source.getVariable()||'mode-0').split('-')[1])||0;source.setVariable('mode-'+(n+1));}",
        "loginUi": ui
    }))
    .unwrap();
    state().sources.push((source, true));
    let rt = runtime(id).unwrap();
    let r = handle("source.loginAction", &json!({"id":id,"index":0})).unwrap();
    assert_eq!(r["message"], "已执行“切换模式”");
    assert_eq!(*rt.variable.lock().unwrap(), "mode-1");
    handle("source.loginAction", &json!({"id":id,"index":0})).unwrap();
    assert_eq!(*rt.variable.lock().unwrap(), "mode-2");
    assert!(handle("source.loginAction", &json!({"id":id,"index":1})).is_err());
    assert!(handle("source.loginAction", &json!({"id":id,"index":7})).is_err());
    assert!(handle("source.loginAction", &json!({"id":id,"action":"fqCycle()"})).is_err());
}
