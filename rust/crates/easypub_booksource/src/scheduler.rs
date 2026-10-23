//! 以章节为工作单元。来源各用自己的运行时/站点配额，共享待下载队列。
use crate::{
    control::{Context, ErrorKind, Profile, Timing},
    download::{self, Failure, Options, Outcome, Progress},
    engine::{Engine, SourceRt},
    webbook::{Book, Chapter},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::Path,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Clone)]
pub struct Lane {
    pub rt: Arc<SourceRt>,
    pub book: Book,
    pub toc: Vec<Chapter>,
    pub mapping: Vec<Option<usize>>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChapterTask {
    pub index: usize,
    pub status: String,
    pub attempts: usize,
    pub error: String,
    pub error_kind: Option<ErrorKind>,
    pub cause: Option<String>,
    pub http_status: Option<u16>,
    pub action: String,
    pub source: String,
    pub chars: usize,
    pub stub: bool,
    pub timing: Timing,
    /// 本轮调度所有尝试累计的请求成本；批量请求按共享章节数分摊。
    pub http_requests: f64,
}
#[derive(Clone)]
struct Job {
    i: usize,
    primary_only: bool,
    single: bool,
    queued: Instant,
}
#[derive(Default)]
struct Work {
    pending: VecDeque<Job>,
    active: usize,
    lane_workers: HashMap<usize, usize>,
    stopped_lanes: HashSet<usize>,
    stop_errors: HashMap<usize, String>,
    limited_rounds: HashMap<usize, (u64, usize)>,
    states: HashMap<usize, ChapterTask>,
    attempts: HashMap<(usize, usize), usize>,
    primary_sizes: Vec<usize>,
    exhausted: HashSet<(usize, usize)>,
    ready: HashMap<(usize, usize), Instant>,
    hashes: HashMap<(usize, String), HashSet<usize>>,
    rejected: HashSet<(usize, String)>,
    current_hash: HashMap<usize, (usize, String)>,
    recent: VecDeque<Instant>,
    done: usize,
}
impl Work {
    fn typical(&self) -> usize {
        self.primary_sizes
            .get(self.primary_sizes.len() / 2)
            .copied()
            .unwrap_or(0)
    }
    fn add_size(&mut self, size: usize) {
        let pos = self.primary_sizes.partition_point(|&n| n < size);
        self.primary_sizes.insert(pos, size);
    }
    fn limited_round(&mut self, lane: usize, epoch: u64) {
        let entry = self.limited_rounds.entry(lane).or_insert((u64::MAX, 0));
        if entry.0 != epoch {
            *entry = (epoch, entry.1 + 1);
        }
        if entry.1 >= 3 {
            self.stopped_lanes.insert(lane);
        }
    }
    fn can_take(&self, lane: usize, job: &Job, lanes: &[Lane]) -> bool {
        !self.stopped_lanes.contains(&lane)
            && !self.exhausted.contains(&(lane, job.i))
            && lanes[lane].mapping[job.i].is_some()
            && (lane == 0 || (!job.primary_only && !self.primary_sizes.is_empty()))
    }
}
pub const THROTTLE_PHRASES: &[&str] = &[
    "访问太频繁",
    "操作过快",
    "频率过高",
    "请求过于频繁",
    "访问频繁",
];
/// 书源 ID 可以是任意标签；按实际正文地址分站，避免同站别名被当成独立源。
pub fn content_site(book: &Book, toc: &[Chapter]) -> Option<String> {
    toc.iter()
        .filter(|c| !c.is_volume)
        .map(|c| c.url.as_str())
        .chain(std::iter::once(book.book_url.as_str()))
        .find_map(|url| {
            let url = reqwest::Url::parse(url).ok()?;
            if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
                return None;
            }
            Some(url.origin().ascii_serialization())
        })
}
pub fn chars(text: &str) -> usize {
    text.chars().filter(|c| !c.is_whitespace()).count()
}
pub fn digest(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}
pub fn median(values: &[usize]) -> usize {
    let mut v = values.to_vec();
    v.sort_unstable();
    v.get(v.len() / 2).copied().unwrap_or(0)
}
pub fn is_stub(text: &str, typical: usize, chapter: &Chapter, extra: &[String]) -> bool {
    content_issue(text, typical, chapter, extra).is_some()
}

/// 只分类，不删改原文。短正文或缺内容不等于站点限流。
pub fn content_issue(
    text: &str,
    typical: usize,
    chapter: &Chapter,
    extra: &[String],
) -> Option<ErrorKind> {
    if chapter.is_volume || chapter.is_pay || chapter.is_vip {
        return None;
    }
    let size = chars(text);
    static WAIT: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"请\s*\d+\s*秒后").unwrap());
    let explicit = extra
        .iter()
        .any(|p| !p.trim().is_empty() && text.contains(p));
    if explicit
        || (size <= 1000
            && (THROTTLE_PHRASES.iter().any(|p| text.contains(p)) || WAIT.is_match(text)))
    {
        return Some(ErrorKind::Throttled);
    }
    if size <= 1000 && text.contains("内容正在获取中") && text.contains("稍候重试") {
        return Some(ErrorKind::ContentUnavailable);
    }
    if size <= 300
        && [
            "请先登录后阅读",
            "请登录后继续阅读",
            "登录后查看本章",
            "会话已过期，请重新登录",
        ]
        .iter()
        .any(|hint| text.contains(hint))
    {
        return Some(ErrorKind::LoginRequired);
    }
    if size < 200.max(typical * 15 / 100) {
        return Some(ErrorKind::ShortContent);
    }
    None
}
pub fn alignment(primary: &[Chapter], other: &[Chapter]) -> Option<Vec<Option<usize>>> {
    let a: Vec<_> = primary
        .iter()
        .enumerate()
        .filter(|(_, c)| !c.is_volume)
        .collect();
    let b: Vec<_> = other
        .iter()
        .enumerate()
        .filter(|(_, c)| !c.is_volume)
        .collect();
    if a.is_empty() || a.len().abs_diff(b.len()) * 100 > a.len().max(b.len()) * 2 {
        return None;
    }
    let mut by_title: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, c) in &b {
        by_title
            .entry(crate::chapter_cleanup::title_key(
                &crate::text::to_num_chapter(&c.title),
            ))
            .or_default()
            .push(*i);
    }
    let mapping: Vec<_> = primary
        .iter()
        .map(|c| {
            by_title
                .get(&crate::chapter_cleanup::title_key(
                    &crate::text::to_num_chapter(&c.title),
                ))
                .filter(|v| v.len() == 1)
                .map(|v| v[0])
        })
        .collect();
    let mut sampled: HashSet<usize> = (0..a.len().min(20))
        .chain(a.len().saturating_sub(20)..a.len())
        .collect();
    let middle: Vec<_> = (20..a.len().saturating_sub(20)).collect();
    let mut pool = middle;
    for _ in 0..20.min(pool.len()) {
        let i = crate::hosts::random(pool.len() as u64) as usize;
        sampled.insert(pool.swap_remove(i));
    }
    if sampled
        .iter()
        .filter(|&&i| mapping[a[i].0].is_some())
        .count()
        * 100
        < sampled.len() * 95
    {
        return None;
    }
    Some(mapping)
}
pub fn write_provenance(
    cache: &Path,
    index: usize,
    source: &str,
    url: &str,
    text: &str,
) -> Result<(), String> {
    let mut meta =
        serde_json::json!({"source":source,"url":url,"chars":chars(text),"hash":digest(text)});
    crate::source::sanitize_json(&mut meta);
    download::write_atomic(
        &cache.join(format!("{index:05}.meta.json")),
        &serde_json::to_vec(&meta).unwrap(),
    )
}
pub fn run(
    lanes: Vec<Lane>,
    book: &Book,
    toc: &[Chapter],
    options: &Options,
    cancel: Arc<AtomicBool>,
    on_progress: Arc<dyn Fn(Progress) + Send + Sync>,
) -> Result<Outcome, String> {
    let started = Instant::now();
    let cache = download::cache_dir(&options.folder, book);
    download::prepare_cache(&cache, toc)?;
    let indices: Vec<_> = download::wanted(toc, options)
        .into_iter()
        .filter(|&i| !toc[i].is_volume)
        .collect();
    let total = indices.len();
    let mut work = Work::default();
    let mut cached = 0;
    for &i in &indices {
        let existing = std::fs::read_to_string(cache.join(format!("{i:05}.txt")))
            .ok()
            .filter(|s| !s.trim().is_empty());
        let mut state = ChapterTask {
            index: i + 1,
            status: "pending".into(),
            source: lanes[0].rt.source.id().into(),
            ..Default::default()
        };
        if let Some(text) = existing {
            cached += 1;
            work.done += 1;
            state.status = "completed".into();
            state.chars = chars(&text);
            let meta = std::fs::read(cache.join(format!("{i:05}.meta.json")))
                .ok()
                .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
            if let Some(source) = meta.as_ref().and_then(|v| v["source"].as_str()) {
                state.source = source.into();
            }
            if let Some(lane) = lanes.iter().position(|l| l.rt.source.id() == state.source) {
                let key = (lane, digest(&text));
                work.hashes.entry(key.clone()).or_default().insert(i);
                work.current_hash.insert(i, key);
            }
            if state.source == lanes[0].rt.source.id() && state.chars >= 200 {
                work.add_size(state.chars);
            }
        } else if options.retry_failed.is_empty() || options.retry_failed.contains(&(i + 1)) {
            work.pending.push_back(Job {
                i,
                primary_only: false,
                single: false,
                queued: Instant::now(),
            });
        } else {
            state.status = "failed".into();
            state.error = "缓存缺失，本次只重试指定失败章节".into();
        }
        work.states.insert(i, state);
    }
    let shared = (Mutex::new(work), Condvar::new());
    // 初始状态也通知持久化；旧任务恢复会以实际缓存为准。
    for state in shared.0.lock().unwrap().states.values() {
        on_progress(Progress {
            total,
            done: cached,
            chapter: Some(state.clone()),
            source_count: lanes.len(),
            ..Default::default()
        });
    }
    std::thread::scope(|scope| {
        for (lane_index, lane) in lanes.iter().enumerate() {
            let threads = lane
                .rt
                .source
                .meta
                .crawl
                .concurrency
                .unwrap_or(if crate::hosts::local(lane.rt.source.base_url()) {
                    16
                } else {
                    options.threads
                })
                .clamp(1, 32);
            for _ in 0..threads.min(total.max(1)) {
                let (shared, cache, cancel, on_progress, lanes) =
                    (&shared, &cache, &cancel, &on_progress, &lanes);
                scope.spawn(move || {
                    let engine = {
                        let mut context = Context::new(Profile::Content, cancel.clone());
                        context.interactive = false;
                        context.crawl = lane.rt.source.meta.crawl.clone();
                        context.deadline = Some(Instant::now() + Duration::from_secs(30));
                        let _guard = context.enter();
                        Engine::new(lane.rt.clone())
                    };
                    let mut host = crate::hosts::host(
                        &content_site(&lane.book, &lane.toc)
                            .unwrap_or_else(|| lane.rt.source.base_url().to_owned()),
                        threads,
                    );
                    loop {
                        let jobs = {
                            let mut w = shared.0.lock().unwrap();
                            loop {
                                if w.active == 0 {
                                    let pending = std::mem::take(&mut w.pending);
                                    w.pending = pending
                                        .into_iter()
                                        .filter(|job| {
                                            (0..lanes.len()).any(|l| w.can_take(l, job, lanes))
                                        })
                                        .collect();
                                }
                                if cancel.load(Ordering::Relaxed)
                                    || w.stopped_lanes.contains(&lane_index)
                                    || (w.pending.is_empty() && w.active == 0)
                                {
                                    return;
                                }
                                let eligible = |j: &Job| {
                                    !w.exhausted.contains(&(lane_index, j.i))
                                        && w.ready
                                            .get(&(lane_index, j.i))
                                            .is_none_or(|at| Instant::now() >= *at)
                                        && (lane_index == 0
                                            || (!j.primary_only
                                                && !w.primary_sizes.is_empty()
                                                && lane
                                                    .mapping
                                                    .get(j.i)
                                                    .is_some_and(Option::is_some)))
                                };
                                // 额度不足时不提前占章，让其他站点仍能从共享队列取走。
                                let pos = if !host.cooling()
                                    && w.lane_workers.get(&lane_index).copied().unwrap_or(0)
                                        < host.snapshot(threads).0
                                {
                                    w.pending.iter().position(eligible)
                                } else {
                                    None
                                };
                                if let Some(pos) = pos {
                                    let first = w.pending.remove(pos).unwrap();
                                    let batch = if first.single {
                                        1
                                    } else {
                                        lane.rt.source.batch_size()
                                    };
                                    let mut jobs = vec![first];
                                    while jobs.len() < batch {
                                        let pos = w.pending.iter().position(|j| {
                                            !j.single
                                                && !w.exhausted.contains(&(lane_index, j.i))
                                                && w.ready
                                                    .get(&(lane_index, j.i))
                                                    .is_none_or(|at| Instant::now() >= *at)
                                                && (lane_index == 0
                                                    || (!j.primary_only
                                                        && lane
                                                            .mapping
                                                            .get(j.i)
                                                            .is_some_and(Option::is_some)))
                                        });
                                        let Some(pos) = pos else {
                                            break;
                                        };
                                        jobs.push(w.pending.remove(pos).unwrap());
                                    }
                                    w.active += jobs.len();
                                    *w.lane_workers.entry(lane_index).or_default() += 1;
                                    for job in &jobs {
                                        *w.attempts.entry((lane_index, job.i)).or_default() += 1;
                                        let state = w.states.get_mut(&job.i).unwrap();
                                        state.attempts += 1;
                                        state.status = "pending".into();
                                        state.source = lane.rt.source.id().into();
                                    }
                                    break jobs;
                                }
                                w = shared
                                    .1
                                    .wait_timeout(w, Duration::from_millis(200))
                                    .unwrap()
                                    .0;
                            }
                        };
                        let mut context = Context::new(Profile::Content, cancel.clone());
                        context.ceiling = Some(threads);
                        context.remove_prompts = options.remove_page_prompts;
                        context.crawl = lane.rt.source.meta.crawl.clone();
                        context.interactive = false;
                        let timing = context.timing.clone();
                        let observed_host = context.observed_host.clone();
                        let _guard = context.enter();
                        let start = Instant::now();
                        let selected: Vec<_> = jobs
                            .iter()
                            .map(|j| lane.toc[lane.mapping[j.i].unwrap()].clone())
                            .collect();
                        let batched =
                            jobs.len() > 1 || (!jobs[0].single && lane.rt.source.batch_size() > 1);
                        let batch = if batched {
                            engine
                                .as_ref()
                                .map_err(Clone::clone)
                                .and_then(|e| e.run(|s| s.chapter_batch(&lane.book, &selected)))
                        } else {
                            Ok(HashMap::new())
                        };
                        for (job, chapter) in jobs.iter().zip(&selected) {
                            let before = Instant::now();
                            let mut result = if batched {
                                batch.as_ref().map_err(Clone::clone).and_then(|batch| {
                                    batch
                                        .get(&chapter.url)
                                        .cloned()
                                        .ok_or_else(|| "批量未回存".to_owned())
                                })
                            } else {
                                let j = lane.mapping[job.i].unwrap();
                                let next = lane.toc[j + 1..]
                                    .iter()
                                    .find(|c| !c.is_volume)
                                    .map(|c| c.url.as_str())
                                    .unwrap_or("");
                                engine.as_ref().map_err(Clone::clone).and_then(|e| {
                                    e.run(|s| s.chapter_content(&lane.book, chapter, next))
                                })
                            };
                            if let Some(actual) = observed_host.lock().unwrap().clone() {
                                host = actual;
                            }
                            let typical = shared.0.lock().unwrap().typical();
                            let mut invalidated = Vec::new();
                            let mut stub = false;
                            // 扫描正文、计算散列不占调度锁。
                            let issue = result.as_ref().ok().and_then(|text| {
                                content_issue(
                                    text,
                                    typical,
                                    chapter,
                                    &lane.rt.source.meta.crawl.throttle_phrases,
                                )
                            });
                            let size = result.as_ref().map_or(0, |text| chars(text));
                            let hash_key = result
                                .as_ref()
                                .ok()
                                .filter(|_| issue.is_none())
                                .map(|text| (lane_index, digest(text)));
                            if let Some(issue) = issue {
                                stub = !issue.requires_action();
                                result = Err(issue.label().into());
                            }
                            let mut w = shared.0.lock().unwrap();
                            if let Some(key) = &hash_key {
                                if let Some(old_key) = w.current_hash.insert(job.i, key.clone())
                                    && old_key != *key
                                    && let Some(indices) = w.hashes.get_mut(&old_key)
                                {
                                    indices.remove(&job.i);
                                }
                                w.hashes.entry(key.clone()).or_default().insert(job.i);
                                let repeated = w.hashes[key].len() >= 3;
                                stub = repeated || w.rejected.contains(key);
                                if repeated && w.rejected.insert(key.clone()) {
                                    let previous: Vec<_> = w.hashes[key]
                                        .iter()
                                        .copied()
                                        .filter(|i| *i != job.i)
                                        .collect();
                                    for i in previous {
                                        let state = w.states.get_mut(&i).unwrap();
                                        if state.status == "completed" {
                                            state.status = "pending".into();
                                            state.error = "疑似限流：多章重复".into();
                                            state.stub = true;
                                            w.done -= 1;
                                            invalidated.push(i + 1);
                                        }
                                    }
                                }
                                if stub {
                                    result = Err("疑似限流桩页".into());
                                } else if lane_index > 0
                                    && (typical == 0
                                        || size < typical * 30 / 100
                                        || size > typical * 3)
                                {
                                    result = Err("替代源字数异常，交回主源".into());
                                }
                            } else if result
                                .as_ref()
                                .err()
                                .is_some_and(|e| e.contains("正文为空"))
                            {
                                stub = true;
                                result = Err("正文为空".into());
                            }
                            drop(w);
                            // 删除完成后才重新入队，避免删除其他线程刚重抓的文件。
                            // 当前 job 在落盘结束前始终算 active，其他线程不会过早退出。
                            let storing = Instant::now();
                            #[cfg(test)]
                            storage_test_hook(cache, job.i);
                            let removed: Vec<_> = invalidated
                                .iter()
                                .map(|index| (*index - 1, discard_cache(cache, *index - 1)))
                                .collect();
                            if let Ok(text) = &result
                                && let Err(e) = write_provenance(
                                    cache,
                                    job.i,
                                    lane.rt.source.id(),
                                    &chapter.url,
                                    text,
                                )
                                .and_then(|()| {
                                    download::write_atomic(
                                        &cache.join(format!("{:05}.txt", job.i)),
                                        text.as_bytes(),
                                    )
                                })
                            {
                                let _ = discard_cache(cache, job.i);
                                result = Err(format!("缓存写入失败：{e}"));
                            }
                            let mut w = shared.0.lock().unwrap();
                            // 写入期间第三个重复响应可能刚刚到达；提交完成状态前再次检查。
                            if result.is_ok()
                                && hash_key
                                    .as_ref()
                                    .is_some_and(|key| w.rejected.contains(key))
                            {
                                drop(w);
                                result = discard_cache(cache, job.i)
                                    .and_then(|()| Err("疑似限流桩页".into()));
                                stub = true;
                                w = shared.0.lock().unwrap();
                            }
                            let store_ms = storing.elapsed().as_millis() as u64;
                            for (i, removed) in removed {
                                match removed {
                                    Ok(()) => w.pending.push_front(Job {
                                        i,
                                        primary_only: false,
                                        single: true,
                                        queued: Instant::now(),
                                    }),
                                    Err(e) => {
                                        let state = w.states.get_mut(&i).unwrap();
                                        state.status = "failed".into();
                                        state.error = e;
                                        state.error_kind = Some(ErrorKind::Storage);
                                    }
                                }
                            }
                            w.active -= 1;
                            if result
                                .as_ref()
                                .err()
                                .is_some_and(|e| ErrorKind::classify(e) == ErrorKind::Throttled)
                            {
                                host.stub();
                            }
                            if result.as_ref().err().is_some_and(|e| {
                                matches!(
                                    ErrorKind::classify(e),
                                    ErrorKind::Throttled | ErrorKind::RateLimited
                                )
                            }) {
                                let epoch = host.diagnostic().learned.last_throttle_at;
                                if epoch > 0 {
                                    w.limited_round(lane_index, epoch);
                                }
                            }
                            let mut t = timing.lock().unwrap().clone();
                            if batched {
                                t.net /= jobs.len() as u64;
                                t.queue /= jobs.len() as u64;
                            }
                            t.parse = (if batched {
                                start.elapsed().as_millis() as u64 / jobs.len() as u64
                            } else {
                                before.elapsed().as_millis() as u64
                            })
                            .saturating_sub(t.net + t.queue + store_ms);
                            t.queue +=
                                start.saturating_duration_since(job.queued).as_millis() as u64;
                            t.store = store_ms;
                            let retries = lane
                                .rt
                                .source
                                .meta
                                .crawl
                                .retries
                                .unwrap_or(options.retries as usize)
                                .min(3);
                            let attempts = w.attempts[&(lane_index, job.i)];
                            let mut state = w.states[&job.i].clone();
                            state.http_requests +=
                                t.requests as f64 / if batched { jobs.len() as f64 } else { 1.0 };
                            state.timing = t.clone();
                            state.stub = stub;
                            match result {
                                Ok(_) => {
                                    w.limited_rounds.remove(&lane_index);
                                    state.status = "completed".into();
                                    state.error.clear();
                                    state.error_kind = None;
                                    state.cause = None;
                                    state.http_status = None;
                                    state.action.clear();
                                    state.chars = size;
                                    w.done += 1;
                                    w.recent.push_back(Instant::now());
                                    if lane_index == 0 {
                                        w.add_size(state.chars);
                                        host.median(w.typical());
                                    }
                                    host.success(threads);
                                }
                                Err(e) => {
                                    let kind = ErrorKind::classify(&e);
                                    state.error = e.clone();
                                    state.error_kind = Some(kind);
                                    state.cause = kind.cause().map(str::to_owned);
                                    state.http_status = ErrorKind::http_status(&e);
                                    state.action = kind.action().into();
                                    if kind.requires_action() || kind == ErrorKind::Storage {
                                        w.stopped_lanes.insert(lane_index);
                                        w.stop_errors.insert(lane_index, e.clone());
                                    }
                                    let missing = batched && e == "批量未回存";
                                    let anomaly = e.contains("字数异常");
                                    let retry = missing
                                        || anomaly
                                        || (kind.retryable()
                                            && attempts
                                                <= if stub { 2.min(retries) } else { retries });
                                    if anomaly {
                                        w.exhausted.insert((lane_index, job.i));
                                    }
                                    if retry
                                        && !w.stopped_lanes.contains(&lane_index)
                                        && (!anomaly || !w.exhausted.contains(&(0, job.i)))
                                    {
                                        state.status = "pending".into();
                                        if !missing && !anomaly {
                                            w.ready.insert(
                                                (lane_index, job.i),
                                                Instant::now()
                                                    + Duration::from_millis(
                                                        1000 * attempts as u64
                                                            + crate::hosts::random(250),
                                                    ),
                                            );
                                        }
                                        w.pending.push_front(Job {
                                            i: job.i,
                                            primary_only: job.primary_only || anomaly,
                                            single: true,
                                            queued: Instant::now(),
                                        });
                                    } else {
                                        w.exhausted.insert((lane_index, job.i));
                                        let other_available = kind != ErrorKind::Storage
                                            && lanes.iter().enumerate().any(|(l, candidate)| {
                                                !w.stopped_lanes.contains(&l)
                                                    && !w.exhausted.contains(&(l, job.i))
                                                    && candidate.mapping[job.i].is_some()
                                                    && (l == 0
                                                        || (!job.primary_only
                                                            && !w.primary_sizes.is_empty()))
                                            });
                                        if other_available {
                                            state.status = "pending".into();
                                            w.pending.push_back(Job {
                                                i: job.i,
                                                primary_only: job.primary_only,
                                                single: true,
                                                queued: Instant::now(),
                                            });
                                        } else {
                                            state.status = "failed".into();
                                        }
                                    }
                                }
                            }
                            w.states.insert(job.i, state.clone());
                            while w
                                .recent
                                .front()
                                .is_some_and(|at| at.elapsed() > Duration::from_secs(10))
                            {
                                w.recent.pop_front();
                            }
                            let speed = w.recent.len() as f64
                                / started.elapsed().as_secs_f64().clamp(0.1, 10.);
                            let (concurrency, throttled) = host.snapshot(threads);
                            let p = Progress {
                                total,
                                done: w.done,
                                failed: w.states.values().filter(|s| s.status == "failed").count(),
                                current: toc[job.i].title.clone(),
                                speed,
                                eta: (speed > 0.)
                                    .then(|| ((total - w.done) as f64 / speed).ceil() as u64),
                                concurrency,
                                retrying: w
                                    .pending
                                    .iter()
                                    .filter(|j| w.states[&j.i].attempts > 0)
                                    .count(),
                                throttled,
                                chapter_ms: start.elapsed().as_millis() as u64,
                                hosts: crate::hosts::diagnostics(),
                                timing: t,
                                chapter: Some(state),
                                invalidated,
                                source_count: lanes.len(),
                            };
                            drop(w);
                            on_progress(p);
                            shared.1.notify_all();
                        }
                        if let Ok(e) = &engine {
                            e.take_logs();
                        }
                        *shared
                            .0
                            .lock()
                            .unwrap()
                            .lane_workers
                            .get_mut(&lane_index)
                            .unwrap() -= 1;
                        shared.1.notify_all();
                    }
                });
            }
        }
    });
    let mut w = shared.0.into_inner().unwrap();
    let cancelled = cancel.load(Ordering::Relaxed);
    if !cancelled {
        let failures = w
            .states
            .values()
            .filter(|s| s.status != "completed")
            .count();
        // 站点停止后未请求的章也记为可重试失败，不能留成永久 pending。
        for state in w.states.values_mut().filter(|s| s.status == "pending") {
            state.status = "failed".into();
            if state.error.is_empty() {
                state.error = lanes
                    .iter()
                    .position(|l| l.rt.source.id() == state.source)
                    .and_then(|l| w.stop_errors.get(&l))
                    .cloned()
                    .unwrap_or_else(|| {
                        "疑似限流：冷却恢复后仍受限，本轮停止本站，请稍后重试失败章节".into()
                    });
            }
            let kind = ErrorKind::classify(&state.error);
            state.error_kind = Some(kind);
            state.cause = kind.cause().map(str::to_owned);
            state.http_status = ErrorKind::http_status(&state.error);
            state.action = kind.action().into();
            on_progress(Progress {
                total,
                done: w.done,
                failed: failures,
                chapter: Some(state.clone()),
                source_count: lanes.len(),
                ..Default::default()
            });
        }
    }
    let path = options
        .folder
        .join(download::file_name(book, &options.file_name));
    if w.states
        .values()
        .any(|s| s.error_kind == Some(ErrorKind::Storage))
    {
        return Err("缓存写入失败，未合成或覆盖 TXT；请检查磁盘与目录权限后重试".into());
    }
    let output_preserved = path.is_file()
        && (cancelled
            || (options.preserve_existing && w.states.values().any(|s| s.status != "completed")));
    let quality = if cancelled || output_preserved {
        crate::chapter_cleanup::toc_quality(toc)
    } else {
        download::assemble(book, toc, options, &path, None)?
    };
    let mut failures: Vec<_> = w
        .states
        .iter()
        .filter(|(_, s)| s.status != "completed")
        .map(|(&i, s)| Failure {
            index: i + 1,
            title: toc[i].title.clone(),
            cause: s.cause.clone(),
            reason: if s.action.is_empty() || s.error.contains(&s.action) {
                s.error.clone()
            } else {
                format!("{}；{}", s.error, s.action)
            },
        })
        .collect();
    failures.sort_by_key(|f| f.index);
    Ok(Outcome {
        path,
        chapters: total,
        downloaded: w.done,
        from_cache: w
            .states
            .values()
            .filter(|s| s.status == "completed" && s.attempts == 0)
            .count(),
        failures,
        cancelled,
        output_preserved,
        quality,
    })
}

#[cfg(test)]
type StorageHook = Arc<dyn Fn(usize) + Send + Sync>;
#[cfg(test)]
static STORAGE_HOOKS: std::sync::LazyLock<Mutex<HashMap<std::path::PathBuf, StorageHook>>> =
    std::sync::LazyLock::new(|| Mutex::new(HashMap::new()));
#[cfg(test)]
fn storage_test_hook(cache: &Path, index: usize) {
    let hook = STORAGE_HOOKS.lock().unwrap().get(cache).cloned();
    if let Some(hook) = hook {
        hook(index);
    }
}

fn discard_cache(cache: &Path, index: usize) -> Result<(), String> {
    for ext in ["txt", "meta.json"] {
        match std::fs::remove_file(cache.join(format!("{index:05}.{ext}"))) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(_) => return Err("缓存写入失败：无法撤回重复正文，请检查下载目录权限".into()),
        }
    }
    Ok(())
}

#[cfg(test)]
mod recovery_tests {
    use super::*;
    #[test]
    fn duplicate_detected_while_other_chapters_are_storing_cannot_commit() {
        let (base, _) = crate::tests::serve(|_| {
            crate::tests::html(&format!(
                "<div id='c'>{}</div>",
                "相同的自拟桩页正文，必须整组撤回。".repeat(30)
            ))
        });
        let rt = SourceRt::new(
            serde_json::from_value(serde_json::json!({
                "bookSourceUrl":base, "ruleContent":{"content":"#c@text"}
            }))
            .unwrap(),
        );
        let book = Book {
            name: "并发撤回夹具".into(),
            origin: base.clone(),
            book_url: format!("{base}/book"),
            ..Default::default()
        };
        let options = Options {
            folder: std::env::temp_dir().join(format!("ep-store-race-{}", std::process::id())),
            retries: 0,
            preserve_existing: true,
            ..Default::default()
        };
        let toc: Vec<_> = (0..3)
            .map(|index| Chapter {
                index,
                title: format!("章节 {index}"),
                url: format!("{base}/{index}"),
                ..Default::default()
            })
            .collect();
        let cache = download::cache_dir(&options.folder, &book);
        let barrier = Arc::new((Mutex::new(0), Condvar::new()));
        STORAGE_HOOKS.lock().unwrap().insert(
            cache.clone(),
            Arc::new(move |_| {
                let (lock, cv) = &*barrier;
                let mut count = lock.lock().unwrap();
                *count += 1;
                cv.notify_all();
                while *count < 3 {
                    let (next, wait) = cv.wait_timeout(count, Duration::from_secs(10)).unwrap();
                    assert!(!wait.timed_out(), "保存正文时仍占用调度锁");
                    count = next;
                }
            }),
        );
        std::fs::create_dir_all(&options.folder).unwrap();
        let path = options
            .folder
            .join(download::file_name(&book, &options.file_name));
        std::fs::write(&path, "需要保留的原成品").unwrap();
        let result = download::download(
            rt,
            &book,
            &toc,
            &options,
            Arc::new(AtomicBool::new(false)),
            Arc::new(|_| {}),
        )
        .unwrap();
        STORAGE_HOOKS.lock().unwrap().remove(&cache);
        assert_eq!(result.failures.len(), 3);
        assert_eq!(result.downloaded, 0);
        assert!(result.output_preserved);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "需要保留的原成品");
        assert!((0..3).all(|i| !cache.join(format!("{i:05}.txt")).exists()));
        std::fs::remove_dir_all(&options.folder).unwrap();
    }
    #[test]
    fn stops_after_two_unsuccessful_recoveries_not_one_failure_wave() {
        let mut work = Work::default();
        for _ in 0..20 {
            work.limited_round(0, 100);
        }
        assert!(!work.stopped_lanes.contains(&0));
        work.limited_round(0, 130);
        assert!(!work.stopped_lanes.contains(&0));
        // 任一成功章结束这段连续失败，之后重新计恢复轮数。
        work.limited_rounds.remove(&0);
        work.limited_round(0, 160);
        work.limited_round(0, 190);
        assert!(!work.stopped_lanes.contains(&0));
        work.limited_round(0, 220);
        assert!(work.stopped_lanes.contains(&0));
        assert!(!work.stopped_lanes.contains(&1));
    }
}
