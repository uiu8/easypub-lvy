//! 持久化书籍任务队列。任务只有在旧 worker 退出后才能再次启动。
use super::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Task {
    pub id: String,
    pub title: String,
    pub source_name: String,
    pub status: String,
    pub params: Value,
    #[serde(default)]
    pub progress: download::Progress,
    #[serde(default)]
    pub result: Option<Value>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub chapters: Vec<crate::scheduler::ChapterTask>,
    #[serde(skip)]
    chapter_index: HashMap<usize, usize>,
}
static CHECKPOINT: Mutex<Option<std::time::Instant>> = Mutex::new(None);
static CHECKPOINT_WRITES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static CHECKPOINT_BYTES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 必须在释放 State 后调用。先取得唯一写者，再取最新快照，防止旧快照覆盖新任务。
fn persist(force: bool) -> Result<(), String> {
    let mut last = if force {
        CHECKPOINT.lock().unwrap()
    } else {
        let Ok(writer) = CHECKPOINT.try_lock() else {
            return Ok(());
        };
        writer
    };
    if !force && last.is_some_and(|at| at.elapsed() < Duration::from_millis(500)) {
        return Ok(());
    }
    let (path, max_books, next_task, tasks) = {
        let st = state();
        (
            st.data.join("tasks.json"),
            st.max_books,
            st.next_task,
            st.queue.clone(),
        )
    };
    let mut value = json!({"version":1,"maxBooks":max_books,"nextTask":next_task,"tasks":tasks});
    source::sanitize_json(&mut value);
    let bytes = serde_json::to_vec(&value).map_err(|_| "任务不能保存")?;
    download::write_atomic(&path, &bytes)?;
    *last = Some(std::time::Instant::now());
    CHECKPOINT_WRITES.fetch_add(1, Ordering::Relaxed);
    CHECKPOINT_BYTES.fetch_add(bytes.len() as u64, Ordering::Relaxed);
    Ok(())
}
fn snapshot() -> Value {
    let st = state();
    let mut value = json!({"tasks":st.queue,"maxBooks":st.max_books,
        "checkpointWrites":CHECKPOINT_WRITES.load(Ordering::Relaxed),
        "checkpointBytes":CHECKPOINT_BYTES.load(Ordering::Relaxed)});
    source::sanitize_json(&mut value);
    value
}
fn changed() {
    send(json!({"event":"queue.changed","queue":snapshot()}));
}
pub(super) fn load() {
    let mut st = state();
    if let Ok(bytes) = std::fs::read(st.data.join("tasks.json"))
        && let Ok(value) = serde_json::from_slice::<Value>(&bytes)
    {
        st.max_books = value["maxBooks"].as_u64().unwrap_or(2).clamp(1, 4) as usize;
        st.next_task = value["nextTask"].as_u64().unwrap_or(0);
        st.queue = serde_json::from_value(value["tasks"].clone()).unwrap_or_default();
        for task in &mut st.queue {
            task.chapter_index = task
                .chapters
                .iter()
                .enumerate()
                .map(|(i, chapter)| (chapter.index, i))
                .collect();
            if task.status == "running" {
                task.status = "paused".into();
            }
        }
    }
}
pub(super) fn shutdown() {
    let mut st = state();
    for flag in st.tasks.values() {
        flag.store(true, Ordering::Relaxed);
    }
    for flag in st.searches.values() {
        flag.store(true, Ordering::Relaxed);
    }
    for task in &mut st.queue {
        if task.status == "running" {
            task.status = "paused".into();
        }
    }
    drop(st);
    let _ = persist(true);
    crate::hosts::wake();
    let _ = crate::hosts::persist();
}
pub(super) fn output_path(params: &Value) -> Option<PathBuf> {
    let book: Book = serde_json::from_value(params["book"].clone()).ok()?;
    let options: Options = serde_json::from_value(params["options"].clone()).ok()?;
    Some(
        options
            .folder
            .join(download::file_name(&book, &options.file_name)),
    )
}
/// 同一本书改输出文件名后仍共享章节缓存，不能同时迁移或写入。
pub(super) fn resources(params: &Value) -> Vec<PathBuf> {
    let mut paths: Vec<_> = output_path(params).into_iter().collect();
    if let (Ok(book), Ok(options)) = (
        serde_json::from_value::<Book>(params["book"].clone()),
        serde_json::from_value::<Options>(params["options"].clone()),
    ) {
        paths.push(download::cache_dir(&options.folder, &book));
    }
    paths
}
pub(super) fn schedule() {
    let jobs = {
        let mut st = state();
        let mut jobs = Vec::new();
        let mut paths: Vec<_> = st
            .queue
            .iter()
            .filter(|t| st.tasks.contains_key(&t.id))
            .flat_map(|t| resources(&t.params))
            .collect();
        for i in 0..st.queue.len() {
            if st.tasks.len() >= st.max_books {
                break;
            }
            let task = &st.queue[i];
            if task.status != "queued" || st.tasks.contains_key(&task.id) {
                continue;
            }
            let needed = resources(&task.params);
            if needed
                .iter()
                .any(|p| paths.contains(p) || st.maintenance_paths.contains(p))
            {
                continue;
            }
            paths.extend(needed);
            let flag = Arc::new(AtomicBool::new(false));
            st.queue[i].status = "running".into();
            let task = st.queue[i].clone();
            st.tasks.insert(task.id.clone(), flag.clone());
            jobs.push((task, flag));
        }
        jobs
    };
    if !jobs.is_empty() {
        let _ = persist(true);
        changed();
    }
    for (task, flag) in jobs {
        std::thread::spawn(move || run_task(task, flag));
    }
}
pub(super) fn start_download(params: &Value) -> Result<Value, String> {
    let book: Book = param(params, "book")?;
    let id: String = param(params, "sourceId")?;
    let options: Options = param(params, "options")?;
    if options.folder.as_os_str().is_empty() {
        return Err("请先设置下载文件夹".into());
    }
    if options
        .from
        .zip(options.to)
        .is_some_and(|(from, to)| from > to)
    {
        return Err("起始章节不能大于结束章节".into());
    }
    let task_id = {
        let mut st = state();
        if let Some(t) = st.queue.iter().find(|t| {
            ["queued", "running", "paused"].contains(&t.status.as_str())
                && t.params["sourceId"] == id
                && t.params["book"]["bookUrl"] == book.book_url
                && output_path(&t.params) == output_path(params)
        }) {
            return Ok(json!({"taskId":t.id,"existing":true}));
        }
        let name = find_source(&st, &id)
            .map(|s| s.book_source_name.trim().to_owned())
            .ok_or("没有这个书源")?;
        st.next_task += 1;
        let task_id = format!("t{}", st.next_task);
        st.queue.push(Task {
            id: task_id.clone(),
            title: book.name,
            source_name: name,
            status: "queued".into(),
            params: params.clone(),
            progress: Default::default(),
            result: None,
            error: None,
            chapters: Vec::new(),
            chapter_index: HashMap::new(),
        });
        task_id
    };
    persist(true)?;
    changed();
    schedule();
    Ok(json!({"taskId":task_id}))
}
pub(super) fn handle(method: &str, params: &Value) -> Result<Value, String> {
    match method {
        "queue.add" => start_download(params),
        "queue.list" => Ok(snapshot()),
        "queue.configure" => {
            let mut st = state();
            st.max_books = params["maxBooks"].as_u64().unwrap_or(2).clamp(1, 4) as usize;
            drop(st);
            persist(true)?;
            changed();
            schedule();
            Ok(snapshot())
        }
        "queue.clearDone" => {
            let mut st = state();
            let running: Vec<_> = st.tasks.keys().cloned().collect();
            st.queue.retain(|t| {
                running.contains(&t.id)
                    || !["done", "failed", "cancelled"].contains(&t.status.as_str())
            });
            drop(st);
            persist(true)?;
            changed();
            Ok(Value::Null)
        }
        "queue.pause" | "queue.resume" | "queue.cancel" | "queue.move" | "queue.retryFailed" => {
            let id = param::<String>(params, "taskId")?;
            let mut st = state();
            let i = st
                .queue
                .iter()
                .position(|t| t.id == id)
                .ok_or("没有这个下载任务")?;
            match method {
                "queue.pause" | "queue.cancel" => {
                    if ["queued", "running", "paused"].contains(&st.queue[i].status.as_str()) {
                        if let Some(flag) = st.tasks.get(&id) {
                            flag.store(true, Ordering::Relaxed);
                        }
                        st.queue[i].status = if method == "queue.pause" {
                            "paused"
                        } else {
                            "cancelled"
                        }
                        .into();
                    }
                }
                "queue.retryFailed" => {
                    if st.tasks.contains_key(&id) {
                        return Err("请等待当前章节请求结束后重试".into());
                    }
                    let failed: Vec<_> = st.queue[i]
                        .chapters
                        .iter()
                        .filter(|c| c.status == "failed")
                        .map(|c| c.index)
                        .collect();
                    if failed.is_empty() {
                        return Err("没有失败章节".into());
                    }
                    st.queue[i].params["options"]["retryFailed"] = json!(failed);
                    st.queue[i].status = "queued".into();
                    st.queue[i].error = None;
                    st.queue[i].result = None;
                }
                "queue.resume" => {
                    if ["paused", "failed", "cancelled"].contains(&st.queue[i].status.as_str()) {
                        st.queue[i].params["options"]["retryFailed"] = json!([]);
                        st.queue[i].status = "queued".into();
                        st.queue[i].error = None;
                        st.queue[i].result = None;
                    }
                }
                "queue.move" => {
                    let offset = if params["direction"] == "up" {
                        -1
                    } else if params["direction"] == "down" {
                        1
                    } else {
                        params["offset"].as_i64().unwrap_or(0)
                    };
                    let to = (i as i64 + offset).clamp(0, st.queue.len().saturating_sub(1) as i64)
                        as usize;
                    let task = st.queue.remove(i);
                    st.queue.insert(to, task);
                }
                _ => (),
            }
            drop(st);
            persist(true)?;
            crate::hosts::wake();
            changed();
            schedule();
            Ok(Value::Null)
        }
        _ => Err("不支持的队列请求".into()),
    }
}
fn run_task(task: Task, cancel: Arc<AtomicBool>) {
    let id = task.params["sourceId"].as_str().unwrap_or("").to_owned();
    let book: Book = serde_json::from_value(task.params["book"].clone()).unwrap_or_default();
    let options: Options =
        serde_json::from_value(task.params["options"].clone()).unwrap_or_default();
    let toc = if task.params["update"] == true && task.params["toc"].is_null() {
        None
    } else {
        serde_json::from_value::<Vec<Chapter>>(task.params["toc"].clone()).ok()
    };
    let alternates: Vec<(String, Book)> = task.params["alternates"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|v| {
                    Some((
                        v["sourceId"].as_str()?.to_owned(),
                        serde_json::from_value(v["book"].clone()).ok()?,
                    ))
                })
                .filter(|(sid, _)| sid != &id)
                .take(6)
                .collect()
        })
        .unwrap_or_default();
    let update = task.params["update"] == true;
    // 搜索补全/调用方已经取得的替代目录也可复用；随后仍做同书与严格对齐检查。
    let prepared_tocs: HashMap<_, Vec<Chapter>> = task.params["alternates"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| {
            let id = v["sourceId"].as_str()?;
            let book: Book = serde_json::from_value(v["book"].clone()).ok()?;
            let toc: Vec<Chapter> = serde_json::from_value(v["toc"].clone()).ok()?;
            (!toc.is_empty()).then(|| (super::enrich::key(id, &book), toc))
        })
        .collect();
    let task = task.id;
    let result = (|| -> Result<Value, String> {
        let _guard =
            crate::control::Context::new(crate::control::Profile::Detail, cancel.clone()).enter();
        let mut id = id.clone();
        let mut book = book;
        let mut rt = runtime(&id)?;
        let toc = match toc {
            Some(t) if !t.is_empty() => t,
            _ => {
                send(json!({ "event": "download.progress", "taskId": task, "stage": "toc" }));
                // 目录读不到或为空时自动换到同一本书的下一个书源。
                let mut candidates = vec![(id.clone(), book.clone())];
                candidates.extend(alternates.iter().cloned());
                let mut last_error = String::from("目录为空");
                let mut found = None;
                for (sid, mut b) in candidates {
                    crate::control::current().check()?;
                    let Ok(r) = runtime(&sid) else { continue };
                    let result = super::enrich::toc(&sid, &mut b, update);
                    match result {
                        Ok(t) if t.iter().any(|c| !c.is_volume) => {
                            found = Some((sid, b, r, t));
                            break;
                        }
                        Ok(_) => last_error = "目录为空".into(),
                        Err(e) => last_error = e,
                    }
                    send(
                        json!({ "event": "download.progress", "taskId": task, "stage": "switch" }),
                    );
                }
                let (sid, b, r, t) =
                    found.ok_or_else(|| format!("各书源都读不到目录：{last_error}"))?;
                id = sid;
                book = b;
                rt = r;
                t
            }
        };
        crate::control::current().check()?;
        {
            let mut st = state();
            if let Some(t) = st.queue.iter_mut().find(|t| t.id == task) {
                t.params["toc"] = json!(toc);
                t.params["book"] = json!(book);
                t.params["update"] = json!(false);
            }
        }
        persist(true)?;
        let mut lanes = Vec::new();
        if options.multi_source && toc.iter().filter(|c| !c.is_volume).count() >= 50 {
            let primary_host = crate::scheduler::content_site(&book, &toc);
            let mut hosts = std::collections::HashSet::new();
            hosts.insert(primary_host);
            for (sid, b) in &alternates {
                if lanes.len() >= options.max_alternates.min(4) {
                    break;
                }
                if b.name != book.name || b.author != book.author {
                    continue;
                }
                let eligible = {
                    let st = state();
                    find_source(&st, sid).is_some_and(|s| {
                        !s.meta.health.cooling_down(now_secs())
                            && !s.tags().contains(&"需验证".into())
                    })
                };
                if !eligible {
                    continue;
                }
                let Ok(alt_rt) = runtime(sid) else {
                    continue;
                };
                let mut b = b.clone();
                let mut ctx = crate::control::current();
                ctx.deadline = Some(std::time::Instant::now() + Duration::from_secs(30));
                ctx.interactive = false;
                let _guard = ctx.enter();
                let other = if let Some(toc) = prepared_tocs.get(&super::enrich::key(sid, &b)) {
                    state()
                        .book_cache
                        .insert(super::enrich::key(sid, &b), (b.clone(), toc.clone()));
                    Ok(toc.clone())
                } else {
                    super::enrich::toc(sid, &mut b, false)
                };
                if let Ok(other) = other
                    && let Some(mapping) = crate::scheduler::alignment(&toc, &other)
                {
                    let host = crate::scheduler::content_site(&b, &other);
                    if host.is_none() || hosts.contains(&host) {
                        continue;
                    }
                    hosts.insert(host);
                    lanes.push(crate::scheduler::Lane {
                        rt: alt_rt,
                        book: b,
                        toc: other,
                        mapping,
                    });
                }
            }
        }
        let output = options
            .folder
            .join(download::file_name(&book, &options.file_name));
        if !options.preserve_existing || !output.is_file() {
            library::record_download(&id, &book, &options, &toc, &output)?;
        }
        let t = task.clone();
        let prior_attempts: HashMap<_, _> = state()
            .queue
            .iter()
            .find(|x| x.id == task)
            .map(|t| t.chapters.iter().map(|c| (c.index, c.attempts)).collect())
            .unwrap_or_default();
        let progress: Arc<dyn Fn(download::Progress) + Send + Sync> = Arc::new(move |mut p| {
            let attempted = p.chapter.as_ref().is_some_and(|c| c.attempts > 0);
            if let Some(c) = &mut p.chapter {
                c.attempts += prior_attempts.get(&c.index).copied().unwrap_or(0);
            }
            {
                let mut st = state();
                if let Some(task) = st.queue.iter_mut().find(|x| x.id == t) {
                    task.progress = p.clone();
                    if let Some(chapter) = &p.chapter {
                        if let Some(&i) = task.chapter_index.get(&chapter.index) {
                            let old = &mut task.chapters[i];
                            let attempts = old.attempts.max(chapter.attempts);
                            *old = chapter.clone();
                            old.attempts = attempts;
                        } else {
                            task.chapter_index
                                .insert(chapter.index, task.chapters.len());
                            task.chapters.push(chapter.clone());
                        }
                    }
                    for index in &p.invalidated {
                        if let Some(&i) = task.chapter_index.get(index) {
                            let c = &mut task.chapters[i];
                            c.status = "pending".into();
                            c.error = "疑似限流：多章重复".into();
                        }
                    }
                }
                if let Some(c) = &p.chapter
                    && attempted
                    && let Some((s, _)) = st.sources.iter_mut().find(|(s, _)| s.id() == c.source)
                {
                    s.meta.downloads.push(source::DownloadSample {
                        at: now_secs(),
                        ms: c.timing.net,
                        ok: c.status == "completed",
                        stub: c.stub,
                    });
                    if s.meta.downloads.len() > 20 {
                        s.meta.downloads.remove(0);
                    }
                }
            }
            // 完成、暂停与取消另有强制检查点；累计失败数不能让所有后续进度都写整份任务。
            let _ = persist(false);
            send(
                json!({ "event": "download.progress", "taskId": t, "stage": "chapters", "progress": p }),
            );
        });
        let mut outcome = download::download_multi(
            rt.clone(),
            &book,
            &toc,
            &options,
            cancel.clone(),
            progress.clone(),
            lanes,
        )?;
        // 失败章节从同一本书的其他书源补全（按章节标题 / 章号对上）。
        if !outcome.failures.is_empty() && !outcome.cancelled && !alternates.is_empty() {
            send(json!({ "event": "download.progress", "taskId": task, "stage": "fill" }));
            let filled =
                fill_from_alternates(&book, &outcome.failures, &options, &alternates, &cancel);
            if filled > 0 {
                let mut again = options.clone();
                again.retries = 0;
                outcome =
                    download::download(rt.clone(), &book, &toc, &again, cancel.clone(), progress)?;
            }
        }
        if !outcome.cancelled && !outcome.output_preserved {
            save_cover(&rt, &book, &outcome.path);
            library::record_download(&id, &book, &options, &toc, &outcome.path)?;
        }
        Ok(
            json!({ "quality": outcome.quality, "libraryKey": format!("{}\n{}", book.origin, book.book_url), "outcome": outcome, "book": book }),
        )
    })();
    let deliver = {
        let mut st = state();
        st.tasks.remove(&task);
        let mut deliver = false;
        if let Some(t) = st.queue.iter_mut().find(|t| t.id == task)
            && t.status == "running"
        {
            deliver = true;
            match &result {
                Ok(v) => {
                    t.status = if v["outcome"]["cancelled"] == true {
                        "cancelled"
                    } else if v["outcome"]["failures"]
                        .as_array()
                        .is_some_and(|f| !f.is_empty())
                    {
                        "failed"
                    } else {
                        "done"
                    }
                    .into();
                    t.result = Some(v.clone());
                }
                Err(e) => {
                    t.status = "failed".into();
                    t.error = Some(e.clone());
                }
            }
        }
        let _ = save(&st);
        deliver
    };
    let _ = persist(true);
    let _ = crate::hosts::persist();
    if deliver {
        match result {
            Ok(v) => send(json!({"event":"download.done","taskId":task,"result":v})),
            Err(e) => send(json!({"event":"download.done","taskId":task,"error":e})),
        }
    }
    changed();
    schedule();
}
fn norm_title(t: &str) -> String {
    crate::text::to_num_chapter(t)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

fn chapter_no(t: &str) -> Option<u64> {
    let t = crate::text::to_num_chapter(t);
    static RE: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"第\s*(\d+)\s*[章节回]").unwrap());
    RE.captures(&t).and_then(|c| c[1].parse().ok())
}

/// 在其他书源里按标题（再按章号）找到失败的章节，取到的写进本书缓存。返回补上的章数。
fn fill_from_alternates(
    book: &Book,
    failures: &[download::Failure],
    options: &Options,
    alternates: &[(String, Book)],
    cancel: &Arc<AtomicBool>,
) -> usize {
    let mut context = crate::control::Context::new(crate::control::Profile::Detail, cancel.clone());
    context.ceiling = Some(2);
    context.remove_prompts = options.remove_page_prompts;
    let _guard = context.enter();
    let cache = download::cache_dir(&options.folder, book);
    // 缺章 -> 是否有书源正在抓它。几个备用书源并行，同一章同一时间只交给一个书源；
    // 抓失败就放回，其他书源还能再试。
    let missing: Mutex<HashMap<usize, (String, bool)>> = Mutex::new(
        failures
            .iter()
            .filter(|f| f.index > 0)
            .map(|f| (f.index - 1, (f.title.clone(), false)))
            .collect(),
    );
    let filled = std::sync::atomic::AtomicUsize::new(0);
    let next = std::sync::atomic::AtomicUsize::new(0);
    let workers = options
        .alternate_concurrency
        .clamp(1, 4)
        .min(alternates.len());
    let context = crate::control::current();
    std::thread::scope(|scope| {
        for _ in 0..workers {
            let (missing, filled, next, cache, context) =
                (&missing, &filled, &next, &cache, context.clone());
            scope.spawn(move || {
                let _guard = context.enter();
                loop {
                    let n = next.fetch_add(1, Ordering::Relaxed);
                    let Some((sid, alt)) = alternates.get(n) else {
                        return;
                    };
                    if missing.lock().unwrap().is_empty() || cancel.load(Ordering::Relaxed) {
                        return;
                    }
                    let got = fill_from_one(sid, alt, missing, cache, cancel);
                    filled.fetch_add(got, Ordering::Relaxed);
                }
            });
        }
    });
    filled.into_inner()
}

/// 用一个备用书源补缺章；返回补回的章数。
fn fill_from_one(
    sid: &str,
    alt: &Book,
    missing: &Mutex<HashMap<usize, (String, bool)>>,
    cache: &std::path::Path,
    cancel: &Arc<AtomicBool>,
) -> usize {
    let Ok(rt) = runtime(sid) else { return 0 };
    let Ok(engine) = Engine::new(rt.clone()) else {
        return 0;
    };
    let mut alt = alt.clone();
    let Ok(toc) = engine.run(|s| {
        if alt.toc_url.is_empty() {
            s.book_info(&mut alt)?;
        }
        s.toc(&alt)
    }) else {
        return 0;
    };
    let mut filled = 0;
    {
        let mut by_title: HashMap<String, Vec<usize>> = HashMap::new();
        let mut by_no: HashMap<u64, Vec<usize>> = HashMap::new();
        for (i, c) in toc.iter().enumerate() {
            if c.is_volume {
                continue;
            }
            by_title.entry(norm_title(&c.title)).or_default().push(i);
            if let Some(n) = chapter_no(&c.title) {
                by_no.entry(n).or_default().push(i);
            }
        }
        // 本书源能对上的缺章（标题或章号唯一对应才算）。
        let locate = |title: &str| {
            by_title
                .get(&norm_title(title))
                .filter(|v| v.len() == 1)
                .map(|v| v[0])
                .or_else(|| {
                    chapter_no(title)
                        .and_then(|n| by_no.get(&n))
                        .filter(|v| v.len() == 1)
                        .map(|v| v[0])
                })
        };
        let mut tried = std::collections::HashSet::new();
        loop {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            // 取一章没试过、没人在抓、本书源对得上的；只剩别人正在抓的就稍等，看对方是否失败放回。
            let (claim, waiting) = {
                let mut m = missing.lock().unwrap();
                let mut waiting = false;
                let mut claim = None;
                for (&index, (title, busy)) in m.iter_mut() {
                    if tried.contains(&index) {
                        continue;
                    }
                    let Some(j) = locate(title) else {
                        tried.insert(index);
                        continue;
                    };
                    if *busy {
                        waiting = true;
                        continue;
                    }
                    *busy = true;
                    claim = Some((index, j));
                    break;
                }
                (claim, waiting)
            };
            let Some((index, j)) = claim else {
                if !waiting {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(50));
                continue;
            };
            tried.insert(index);
            let next = toc[j + 1..]
                .iter()
                .find(|c| !c.is_volume)
                .map(|c| c.url.clone())
                .unwrap_or_default();
            let ok = match engine.run(|s| s.chapter_content(&alt, &toc[j], &next)) {
                Ok(text)
                    if !crate::scheduler::is_stub(
                        &text,
                        0,
                        &toc[j],
                        &rt.source.meta.crawl.throttle_phrases,
                    ) =>
                {
                    download::write_atomic(&cache.join(format!("{index:05}.txt")), text.as_bytes())
                        .is_ok()
                        && {
                            let _ = crate::scheduler::write_provenance(
                                cache,
                                index,
                                sid,
                                &toc[j].url,
                                &text,
                            );
                            true
                        }
                }
                _ => false,
            };
            let mut m = missing.lock().unwrap();
            if ok {
                m.remove(&index);
                filled += 1;
            } else if let Some(entry) = m.get_mut(&index) {
                entry.1 = false;
            }
        }
    }
    filled
}

/// 封面存到 TXT 旁边（同名图片），已有时不重复下载。
fn save_cover(rt: &Arc<SourceRt>, book: &Book, txt: &std::path::Path) {
    if !book.cover_url.starts_with("http") {
        return;
    }
    let request = crate::net::Request {
        url: book.cover_url.clone(),
        method: "GET".into(),
        ..Default::default()
    };
    let Ok(r) = rt.net.fetch(&request) else {
        return;
    };
    let kind = r.header("content-type").unwrap_or("").to_ascii_lowercase();
    let image = kind.starts_with("image") || matches!(r.body.first(), Some(0xFF | 0x89));
    if r.body.len() < 512 || !image {
        return;
    }
    let ext = if kind.contains("png") {
        "png"
    } else if kind.contains("webp") {
        "webp"
    } else if kind.contains("gif") {
        "gif"
    } else {
        "jpg"
    };
    let path = txt.with_extension(ext);
    if !path.exists() {
        let _ = std::fs::write(path, &r.body);
    }
}
