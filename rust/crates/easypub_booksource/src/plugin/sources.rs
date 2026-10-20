//! 来源分组、健康记录、测速与校验；规则存储继续兼容阅读 JSON 数组。
use super::*;
use crate::{
    control::{Context, Profile},
    net::{Net, Request},
    source::SourceMeta,
};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashSet, VecDeque},
    time::Instant,
};

fn file(source: &BookSource) -> &str {
    if source.meta.file.is_empty() {
        "旧版导入"
    } else {
        &source.meta.file
    }
}

pub(super) fn summary(source: &BookSource, enabled: bool, duplicate: bool) -> Value {
    let problems = support::check(source);
    let mut reasons: Vec<_> = problems.iter().map(|p| p.message()).collect();
    if source.variable_comment.contains("easypub:cookie-removed") {
        reasons.push(
            "书源自带的 Cookie 已去掉（不保存），其他凭据同样不落盘；需要登录时请使用登录入口"
                .into(),
        );
    }
    reasons.extend(source.meta.import_warnings.clone());
    let cause = support::cause(&problems)
        .or_else(|| source.meta.check.as_ref().and_then(|c| c["cause"].as_str()));
    json!({"pinned":source.meta.pinned,"customOrder":source.custom_order,"rating":source.meta.rating,"autoWeight":source.auto_weight(),"weight":source.weight,
        "cause":cause,"unsupported":problems.iter().filter(|p|!matches!(p,support::Problem::NoSearch|support::Problem::NoContentRule)).map(|p|p.message()).collect::<Vec<_>>(),
        "tags":source.tags(),"recommended":source.recommended(),"id":source.id(), "url":source.book_source_url, "name":source.book_source_name.trim(),
        "group":source.book_source_group, "groups":source.groups(), "file":file(source), "importedAt":source.meta.imported_at,
        "enabled":enabled, "supported":problems.is_empty(), "reasons":reasons, "webView":support::needs_web_view(source),
        "login":!source.login_url.trim().is_empty(), "check":source.meta.check, "ping":source.meta.ping, "health":source.meta.health,
        "format":if source.html.is_empty() {"阅读 / 规则"} else {"轻悦时光 HTML（文字）"},
        "duplicate":duplicate, "updated":source.meta.updated})
}

pub(super) use crate::source::sanitize_json;

/// 导入偏好：新书源放最前 / 最后；重新导入同一书源时是否改用新文件的名称、分组。
/// 文件导入、网址导入和订阅更新共用；单独存放，取用时不碰全局状态锁。
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub(super) struct ImportOptions {
    pub position: String,
    pub override_name: bool,
    pub override_group: bool,
}
impl Default for ImportOptions {
    fn default() -> Self {
        // 名称照旧随新文件；分组默认保留用户整理过的，与订阅更新一致。
        Self {
            position: "bottom".into(),
            override_name: true,
            override_group: false,
        }
    }
}
static IMPORT_OPTIONS: Mutex<Option<ImportOptions>> = Mutex::new(None);
pub(super) fn import_options() -> ImportOptions {
    IMPORT_OPTIONS.lock().unwrap().clone().unwrap_or_default()
}
pub(super) fn load_import_options(dir: &std::path::Path) {
    let options = std::fs::read(dir.join("import.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<ImportOptions>(&b).ok())
        .unwrap_or_default();
    *IMPORT_OPTIONS.lock().unwrap() = Some(options);
}
fn set_import_options(params: &Value) -> Result<Value, String> {
    let options: ImportOptions = param(params, "options")?;
    if !matches!(options.position.as_str(), "top" | "bottom") {
        return Err("新书源位置只能是最前或最后".into());
    }
    let path = state().data.join("import.json");
    download::write_atomic(&path, &serde_json::to_vec(&options).unwrap())?;
    *IMPORT_OPTIONS.lock().unwrap() = Some(options.clone());
    Ok(json!(options))
}

/// 已有书源被新文件更新时，按偏好保留用户原来的名称 / 分组。
pub(super) fn keep_user_fields(new: &mut BookSource, old: &BookSource, options: &ImportOptions) {
    if !options.override_name {
        new.book_source_name = old.book_source_name.clone();
    }
    if !options.override_group {
        new.book_source_group = old.book_source_group.clone();
    }
}

pub(super) fn import_text(text: &str, origin: &str) -> Result<Value, String> {
    let (sources, skipped) = source::import(text)?;
    let options = import_options();
    let mut st = state();
    let (mut added, mut updated) = (0, 0);
    let mut fresh = Vec::new();
    for s in sources {
        let mut value = serde_json::to_value(&s).map_err(|_| "书源不能序列化")?;
        let stripped = sanitize_json(&mut value);
        let mut s: BookSource = serde_json::from_value(value).map_err(|_| "书源不能读取")?;
        if stripped {
            s.variable_comment.push_str("\neasypub:cookie-removed");
        }
        let slot = st.sources.iter().position(|(x, _)| {
            x.book_source_url == s.book_source_url && (file(x) == origin || x.meta.file.is_empty())
        });
        if let Some(i) = slot {
            let (old, enabled) = &st.sources[i];
            keep_user_fields(&mut s, old, &options);
            let mut a = serde_json::to_value(old).unwrap();
            let mut b = serde_json::to_value(&s).unwrap();
            a.as_object_mut().unwrap().remove("easypub");
            b.as_object_mut().unwrap().remove("easypub");
            let changed = a != b;
            s.meta = old.meta.clone();
            s.meta.file = origin.to_owned();
            s.meta.updated = changed;
            if changed {
                s.meta.health.retry_after = 0;
            }
            let enabled = *enabled;
            st.runtimes.remove(s.id());
            st.sources[i] = (s, enabled);
            updated += usize::from(changed);
        } else {
            let duplicate = st
                .sources
                .iter()
                .any(|(x, _)| x.book_source_url == s.book_source_url);
            let id = if duplicate {
                let hash = hex::encode(Sha256::digest(format!("{origin}\n{}", s.book_source_url)));
                format!("{}::{}", s.book_source_url, &hash[..12])
            } else {
                s.book_source_url.clone()
            };
            s.meta = SourceMeta {
                id,
                file: origin.into(),
                imported_at: now_secs(),
                ..s.meta.clone()
            };
            let enabled = support::check(&s).is_empty();
            fresh.push(st.sources.len());
            st.sources.push((s, enabled));
            added += 1;
        }
    }
    // 新书源排在已有书源的最前或最后，彼此保持文件里的顺序。
    let existing = st
        .sources
        .iter()
        .enumerate()
        .filter(|(i, _)| !fresh.contains(i))
        .map(|(_, (s, _))| s.custom_order);
    let (top, bottom) = (
        existing.clone().min().unwrap_or(0),
        existing.max().unwrap_or(-1),
    );
    let n = fresh.len() as i64;
    for (k, &i) in fresh.iter().enumerate() {
        st.sources[i].0.custom_order = if options.position == "top" {
            top - n + k as i64
        } else {
            bottom + 1 + k as i64
        };
    }
    save(&st)?;
    Ok(json!({"added":added,"updated":updated,"skipped":skipped,"total":st.sources.len()}))
}

fn ids(params: &Value) -> Result<Vec<String>, String> {
    param(params, "ids")
}

pub(super) fn handle(method: &str, params: &Value) -> Result<Value, String> {
    if matches!(
        method,
        "sources.pin"
            | "sources.order"
            | "sources.rate"
            | "sources.tags"
            | "sources.crawlProfile.get"
            | "sources.crawlProfile.set"
    ) {
        return management::source(method, params);
    }
    match method {
        "sources.causes" => {
            let st = state();
            let mut causes = std::collections::BTreeMap::<String, usize>::new();
            let mut unsupported = std::collections::BTreeMap::<String, usize>::new();
            for (s, enabled) in &st.sources {
                let item = summary(s, *enabled, false);
                let cause = item["cause"].as_str().unwrap_or(
                    if s.meta.check.as_ref().is_some_and(|v| v["ok"] == true) {
                        "ok"
                    } else {
                        "untested"
                    },
                );
                *causes.entry(cause.into()).or_default() += 1;
                let issues = if item["unsupported"]
                    .as_array()
                    .is_some_and(|a| !a.is_empty())
                {
                    &item["unsupported"]
                } else {
                    &item["check"]["unsupported"]
                };
                for name in issues
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                {
                    *unsupported.entry(name.into()).or_default() += 1;
                }
            }
            let mut ranking: Vec<_> = unsupported.into_iter().collect();
            ranking.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
            Ok(
                json!({"causes":causes,"unsupported":ranking.into_iter().map(|(name,count)|json!({"name":name,"count":count})).collect::<Vec<_>>()}),
            )
        }
        "sources.importOptions.get" => Ok(json!(import_options())),
        "sources.importOptions.set" => set_import_options(params),
        "sources.import" => {
            let path: String = param(params, "path")?;
            let text = std::fs::read_to_string(&path).map_err(|_| "无法读取书源文件")?;
            import_text(&text, &path)
        }
        "__import_body" => import_text(
            &param::<String>(params, "text")?,
            params["file"].as_str().unwrap_or("直接导入"),
        ),
        "sources.updateFile" => subscriptions::handle("subscriptions.preview", params),
        "sources.importUrl" => {
            let url = params["url"]
                .as_str()
                .or(params["file"].as_str())
                .ok_or("没有来源网址")?;
            if !url.starts_with("http://") && !url.starts_with("https://") {
                return Err("这个来源不是网址，请重新选择文件导入".into());
            }
            let mut net = Net::new(None, vec![]);
            net.crawl.proxy_mode = "proxy".into();
            let mut context = crate::control::current();
            context.profile = Profile::Import;
            context.deadline = Some(Instant::now() + Duration::from_secs(120));
            let _guard = context.enter();
            let response = net
                .fetch(&Request {
                    url: url.into(),
                    method: "GET".into(),
                    ..Default::default()
                })
                .map_err(|e| e.0)?;
            if response.status >= 400 {
                return Err(format!("网站返回 {}", response.status));
            }
            subscriptions::import(&response.text, url)
        }
        "sources.list" => {
            let st = state();
            let mut counts = HashMap::<&str, usize>::new();
            for (s, _) in &st.sources {
                *counts.entry(&s.book_source_url).or_default() += 1;
            }
            Ok(json!(
                st.sources
                    .iter()
                    .map(|(s, e)| summary(s, *e, counts[s.book_source_url.as_str()] > 1))
                    .collect::<Vec<_>>()
            ))
        }
        "sources.groups" => {
            let st = state();
            let mut groups = std::collections::BTreeMap::<String, Vec<Value>>::new();
            for (s, e) in &st.sources {
                let keys = if params["by"] == "group" {
                    let g = s.groups();
                    if g.is_empty() {
                        vec!["未分组".into()]
                    } else {
                        g
                    }
                } else {
                    vec![file(s).into()]
                };
                for key in keys {
                    groups.entry(key).or_default().push(summary(s, *e, false));
                }
            }
            Ok(json!(groups.into_iter().map(|(name,items)| json!({"name":name,"count":items.len(),
                "ok":items.iter().filter(|s|s["health"]["lastOk"].as_u64().unwrap_or(0)>0 && s["health"]["failStreak"]==0).count(),
                "failed":items.iter().filter(|s|s["health"]["failStreak"].as_u64().unwrap_or(0)>0).count(),
                "ids":items.iter().map(|s|s["id"].clone()).collect::<Vec<_>>() })).collect::<Vec<_>>()))
        }
        "sources.setEnabled" | "sources.setEnabledMany" => {
            let ids = ids(params)?;
            let enabled = param::<bool>(params, "enabled")?;
            let mut st = state();
            for (s, e) in &mut st.sources {
                if ids.iter().any(|id| id == s.id()) {
                    *e = enabled;
                }
            }
            save(&st)?;
            Ok(Value::Null)
        }
        "sources.remove" | "sources.removeMany" => {
            let ids = ids(params)?;
            let mut st = state();
            st.sources
                .retain(|(s, _)| !ids.iter().any(|id| id == s.id()));
            for id in ids {
                st.runtimes.remove(&id);
            }
            save(&st)?;
            Ok(Value::Null)
        }
        "sources.setGroup" => {
            let ids = ids(params)?;
            let group = param::<String>(params, "group")?;
            let mut st = state();
            for (s, _) in &mut st.sources {
                if ids.iter().any(|id| id == s.id()) {
                    s.book_source_group = group.clone();
                }
            }
            save(&st)?;
            Ok(Value::Null)
        }
        "sources.dedupe" => {
            let action = params["action"].as_str().unwrap_or("disable");
            if !["disable", "delete"].contains(&action) {
                return Err("请选择停用或删除重复书源".into());
            }
            let mut st = state();
            let mut best = HashMap::new();
            for (i, (s, _)) in st.sources.iter().enumerate() {
                let e = best.entry(s.book_source_url.clone()).or_insert(i);
                if s.last_update_time > st.sources[*e].0.last_update_time {
                    *e = i;
                }
            }
            let losers: HashSet<_> = st
                .sources
                .iter()
                .enumerate()
                .filter(|(i, (s, _))| best[&s.book_source_url] != *i)
                .map(|(_, (s, _))| s.id().to_owned())
                .collect();
            if action == "delete" {
                st.sources.retain(|(s, _)| !losers.contains(s.id()));
            } else {
                for (s, e) in &mut st.sources {
                    if losers.contains(s.id()) {
                        *e = false;
                    }
                }
            }
            for id in &losers {
                st.runtimes.remove(id);
            }
            save(&st)?;
            Ok(json!({"changed":losers.len(),"action":action}))
        }
        "sources.export" => {
            let ids = ids(params)?;
            let mut values: Vec<_> = state()
                .sources
                .iter()
                .filter(|(s, _)| ids.iter().any(|id| id == s.id()))
                .map(|(s, e)| {
                    let mut v = serde_json::to_value(s).unwrap();
                    v.as_object_mut().unwrap().remove("easypub");
                    v["enabled"] = json!(e);
                    v
                })
                .collect();
            for value in &mut values {
                sanitize_json(value);
            }
            if let Some(path) = params["path"].as_str() {
                download::write_atomic(
                    std::path::Path::new(path),
                    &serde_json::to_vec_pretty(&values).unwrap(),
                )?;
            }
            Ok(json!({"count":values.len(),"sources":values,"path":params["path"]}))
        }
        "sources.detail" => {
            let id = param::<String>(params, "id")?;
            let st = state();
            let (s, _) = st
                .sources
                .iter()
                .find(|(s, _)| s.id() == id)
                .ok_or("没有这个书源")?;
            Ok(
                json!({"id":s.id(),"name":s.book_source_name,"url":s.book_source_url,"ruleSearch":s.rule_search,
                "ruleBookInfo":s.rule_book_info,"ruleToc":s.rule_toc,"ruleContent":s.rule_content,"concurrentRate":s.concurrent_rate,
                "webView":support::needs_web_view(s),"login":!s.login_url.is_empty(),"enabled":s.enabled,"group":s.book_source_group,"header":s.header,"tags":s.tags(),"health":s.meta.health,"downloads":s.meta.downloads,"crawl":s.meta.crawl,"suggestion":s.meta.crawl_suggestion,"learned":crate::hosts::host(s.base_url(),32).diagnostic().learned,"warnings":s.meta.import_warnings,"rating":s.meta.rating}),
            )
        }
        "sources.ping" => probe(params, true),
        "sources.check" => probe(params, false),
        _ => Err("不支持的书源管理请求".into()),
    }
}

pub(super) fn record_health(
    id: &str,
    ms: u64,
    ok: bool,
    error: &str,
    check: Option<Value>,
) -> Value {
    let mut st = state();
    let Some((s, _)) = st.sources.iter_mut().find(|(s, _)| s.id() == id) else {
        return Value::Null;
    };
    s.meta.health.record(ms, ok, error, now_secs());
    if let Some(check) = check {
        s.meta.check = Some(check);
    }
    json!(s.meta.health)
}

pub(super) fn retry_after_network_change() -> Result<(), String> {
    let mut st = state();
    for (source, _) in &mut st.sources {
        source.meta.health.retry_after = 0;
    }
    save(&st)
}

fn probe(params: &Value, ping: bool) -> Result<Value, String> {
    let wanted = params["ids"].as_array();
    let list: Vec<_> = state()
        .sources
        .iter()
        .filter(|(s, e)| wanted.map_or(*e, |ids| ids.iter().any(|id| id == s.id())))
        .map(|(s, _)| {
            (
                s.id().to_owned(),
                s.base_url().to_owned(),
                BookSource::rule(&s.rule_search, "checkKeyWord").to_owned(),
                s.meta.crawl.clone(),
            )
        })
        .collect();
    let total = list.len();
    let workers = params["concurrency"]
        .as_u64()
        .unwrap_or(if ping { 32 } else { 8 })
        .clamp(1, 64) as usize;
    let queue = Mutex::new(VecDeque::from(list));
    let done = std::sync::atomic::AtomicUsize::new(0);
    let ok = std::sync::atomic::AtomicUsize::new(0);
    let keyword = params["key"].as_str().unwrap_or("").trim().to_owned();
    std::thread::scope(|scope| {
        for _ in 0..workers.min(total) {
            let (queue, done, ok, keyword) = (&queue, &done, &ok, &keyword);
            scope.spawn(move || {
                loop {
                    let Some((id,url,key,crawl))=queue.lock().unwrap().pop_front() else {break;};
                    let start=Instant::now(); let mut context=Context::new(if ping {Profile::Ping}else{Profile::Detail},Arc::new(AtomicBool::new(false)));
                    context.deadline=Some(start+Duration::from_secs(if ping {5}else{40})); context.interactive=false; context.crawl=crawl.clone();
                    let network_route=context.network_route.clone();
                    let _guard=context.enter();
                    let mut report = crate::probe::Check { stage: if ping {"connect"} else {"engine"}, ..Default::default() };
                    let result=if ping {
                        let mut net=Net::new(None,vec![]); net.crawl=crawl;
                        net.fetch(&Request{url,method:"GET".into(),..Default::default()}).map_err(|e|e.0).and_then(|r|if r.status<400 {Ok(r.status)}else{Err(format!("网站返回 {}",r.status))})
                    } else {
                        with_engine(&id,|e| {
                            let key=if !keyword.is_empty(){keyword.as_str()}else if !key.is_empty(){&key}else{"我的"};
                            crate::probe::check(e,key,&mut report)
                        })
                    };
                    let ms=start.elapsed().as_millis() as u64;
                    if report.cause.is_none() {
                        report.cause=result.as_ref().err().and_then(|e|crate::control::ErrorKind::classify(e).cause());
                    }
                    let error=result.as_ref().err().map(|e|crate::probe::reason(e)).unwrap_or("");
                    let success=result.is_ok(); if success{ok.fetch_add(1,Ordering::Relaxed);}
                    let mut v=serde_json::to_value(report).unwrap();
                    let map=v.as_object_mut().unwrap();
                    map.insert("route".into(),network_route.lock().unwrap().clone());
                    map.extend(json!({"kind":if ping{"ping"}else{"check"},"ok":success,"ms":ms,"status":result.as_ref().ok(),"error":error,"at":now_secs()}).as_object().unwrap().clone());
                    let health=if ping {
                        let mut st=state();
                        if let Some((s,_))=st.sources.iter_mut().find(|(s,_)|s.id()==id) {
                            s.meta.health.latency(ms);
                            s.meta.ping=Some(v.clone());
                            json!(s.meta.health)
                        } else {Value::Null}
                    } else {record_health(&id,ms,success,error,Some(v.clone()))};
                    let n=done.fetch_add(1,Ordering::Relaxed)+1;
                    v["event"]=json!(if ping{"ping.result"}else{"check.result"});
                    v["id"]=json!(id);
                    v["health"]=health;
                    send(v);
                    send(json!({"event":if ping{"ping.progress"}else{"check.progress"},"done":n,"total":total,"ok":ok.load(Ordering::Relaxed)}));
                }
            });
        }
    });
    save(&state())?;
    Ok(json!({"total":total,"ok":ok.load(Ordering::Relaxed)}))
}
