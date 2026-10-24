//! Read-only, cancellable background analysis of an immutable publication request.
use crate::{publication_resources, sessions::ImportService};
use easypub_core::{ApiError, ErrorCode, publication::EffectiveBook, source::SourceSnapshot};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Instant,
};

#[path = "rule_statistics_cleanup.rs"]
pub(crate) mod cleanup;
#[path = "rule_statistics_hypothetical.rs"]
mod hypothetical;
#[path = "rule_statistics_interactions.rs"]
mod interactions;
#[path = "rule_statistics_layout.rs"]
mod layout;
#[path = "rule_statistics_recognition.rs"]
mod recognition;

fn error(reason: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "rule_statistics", reason)
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
/// 把彼此独立的整本书遍历分给多个线程（V83）：最多 8 个工作线程，结果按输入顺序返回，
/// 与逐个计算完全相同；只有一项或单核时直接按顺序计算。
fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let workers = std::thread::available_parallelism()
        .map_or(1, |n| n.get())
        .clamp(1, 8)
        .min(items.len());
    if workers <= 1 {
        return items.iter().map(&f).collect();
    }
    let next = std::sync::atomic::AtomicUsize::new(0);
    let (f, next) = (&f, &next);
    let parts: Vec<Vec<(usize, R)>> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..workers)
            .map(|_| {
                scope.spawn(move || {
                    let mut out = Vec::new();
                    loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        if i >= items.len() {
                            break;
                        }
                        out.push((i, f(&items[i])));
                    }
                    out
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().expect("statistics worker"))
            .collect()
    });
    let mut slots: Vec<Option<R>> = (0..items.len()).map(|_| None).collect();
    for (i, r) in parts.into_iter().flatten() {
        slots[i] = Some(r);
    }
    slots.into_iter().map(|r| r.expect("every item")).collect()
}

fn checkpoint(cancel: &AtomicBool) -> Result<(), ApiError> {
    if cancel.load(Ordering::Relaxed) {
        Err(ApiError::new(
            ErrorCode::Cancelled,
            "rule_statistics",
            "request_statistics_again",
        ))
    } else {
        Ok(())
    }
}

#[derive(Clone, Serialize)]
struct Statistic {
    id: String,
    enabled: bool,
    hypothetical: bool,
    count: usize,
    unit: &'static str,
    status: &'static str,
    locations: Vec<Value>,
    changed_ranges: Vec<(u32, u32)>,
    candidate_ranges: Vec<(u32, u32)>,
    invalid_count: usize,
    affects: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
}
type Statistics = BTreeMap<String, Statistic>;
impl Statistic {
    fn hit(&mut self, location: Value) {
        self.count += 1;
        if self.locations.len() < 50 && !location.is_null() {
            self.locations.push(location);
        }
    }
}

/// Effective source-line numbers and V53 body-line numbers are deliberately separate.
struct Locations<'a> {
    book: &'a EffectiveBook,
    lines: &'a [(usize, usize)],
}
impl Locations<'_> {
    fn line(&self, line: u32) -> Value {
        let Some(&(offset, _)) = self.lines.get(line.saturating_sub(1) as usize) else {
            return Value::Null;
        };
        self.byte(offset)
    }
    fn byte(&self, offset: usize) -> Value {
        let source_line = self.lines.partition_point(|&(a, _)| a <= offset);
        let node = self
            .book
            .tree
            .nodes
            .partition_point(|n| n.start <= offset)
            .checked_sub(1)
            .map(|i| &self.book.tree.nodes[i]);
        let (entry, body, heading) = node.map_or(("$prefix", 0, false), |n| {
            (n.entry_id.as_str(), n.body_start, offset < n.body_start)
        });
        let line = if heading {
            0
        } else {
            source_line - self.lines.partition_point(|&(a, _)| a < body)
        };
        json!({"entry_id":entry,"first_line":line,"last_line":line,"heading":heading,"source_line":source_line,"utf8_start":offset})
    }
}

pub(crate) fn calculate(
    source: &SourceSnapshot,
    request: publication_resources::Request,
    pipeline: Value,
    cancel: &AtomicBool,
) -> Result<Value, ApiError> {
    let started = Instant::now();
    checkpoint(cancel)?;
    let (book, settings) = publication_resources::compose(source, request)?;
    checkpoint(cancel)?;
    let view = SourceSnapshot::for_effective_diagnostics(&book)?;
    let locations = Locations {
        book: &book,
        lines: view.decoded_line_ranges(),
    };
    let mut stats: Statistics = crate::rule_catalog::catalog()["rules"]
        .as_array()
        .expect("catalog")
        .iter()
        .map(|r| {
            let id = r["id"].as_str().expect("id").to_owned();
            let unit = match r["group"].as_str().expect("group") {
                "chapter_recognition" => "titles",
                "chapter_check" => "issues",
                "cleanup" => "lines",
                _ => "blocks",
            };
            (
                id.clone(),
                Statistic {
                    id,
                    enabled: r["default"].as_bool().expect("default"),
                    hypothetical: false,
                    count: 0,
                    unit,
                    status: "complete",
                    locations: vec![],
                    changed_ranges: vec![],
                    candidate_ranges: vec![],
                    invalid_count: 0,
                    affects: vec![],
                    reason: None,
                },
            )
        })
        .collect();
    // 清理统计只改 cleanup.* 行，识别与排版统计只改各自的行：两组同时算，再按前缀合并（V83）。
    let mut cleanup_stats = stats.clone();
    let mut layout_lines = layout::LayoutLines::new();
    let (cleaned, others) = std::thread::scope(|scope| {
        let cleaned = scope
            .spawn(|| cleanup::collect(&view, &pipeline, &locations, &mut cleanup_stats, cancel));
        let others = (|| {
            recognition::collect(&view, &locations, &mut stats, cancel)?;
            recognition::collect_checks(&view, &locations, &mut stats, cancel)?;
            checkpoint(cancel)?;
            layout::collect(
                &book,
                &settings,
                &locations,
                &mut stats,
                Some(&mut layout_lines),
                cancel,
            )
        })();
        (cleaned.join().expect("cleanup statistics"), others)
    });
    cleaned?;
    others?;
    checkpoint(cancel)?;
    for (id, row) in cleanup_stats {
        if id.starts_with("cleanup.") {
            stats.insert(id, row);
        }
    }
    for row in crate::rule_catalog::catalog()["rules"].as_array().unwrap() {
        let id = row["id"].as_str().unwrap();
        stats.get_mut(id).unwrap().enabled = crate::rule_toggles::enabled(
            row,
            &book.tree.recognition_rules.clone().unwrap_or_default(),
            &settings,
            &pipeline,
        );
        if row["group"] == "catalog_check" || row["group"] == "preflight" {
            let r = stats.get_mut(id).unwrap();
            r.status = "unavailable";
            r.reason = Some("缺少参考目录或输出上下文".into());
        }
    }
    let invalid =
        stats["layout.manual_block"].invalid_count + stats["layout.manual_note"].invalid_count;
    stats.get_mut("manual.invalid").unwrap().count = invalid;
    // 规则交互只追加 affects，假设统计只改关闭规则的计数：读同一份统计，同时算后合并（V83）。
    let mut interaction_stats = stats.clone();
    let (interacted, supposed) = std::thread::scope(|scope| {
        let interacted = scope.spawn(|| {
            interactions::collect(
                &book,
                &settings,
                &pipeline,
                &locations,
                &mut interaction_stats,
                cancel,
            )
        });
        let supposed =
            hypothetical::collect(&book, &settings, &pipeline, &locations, &mut stats, cancel);
        (interacted.join().expect("interaction statistics"), supposed)
    });
    interacted?;
    supposed?;
    for (id, row) in interaction_stats {
        stats.get_mut(&id).expect("rule").affects = row.affects;
    }
    checkpoint(cancel)?;
    Ok(
        json!({"schema":1,"read_only":true,"content_id":digest(book.text.as_bytes()),
        "source_id":source.summary().source_id,"revision":source.summary().revision,
        "byte_length":book.text.len(),"line_count":locations.lines.len(),"chapter_count":book.tree.nodes.len(),
        "elapsed_ms":started.elapsed().as_secs_f64()*1000.0,"rules":stats.into_values().collect::<Vec<_>>(),
        "layout_lines":layout_lines }),
    )
}

struct Job {
    cancel: Arc<AtomicBool>,
    released: bool,
    phase: &'static str,
    result: Option<Value>,
    error: Option<Value>,
}
#[derive(Default)]
struct State {
    sequence: u64,
    jobs: BTreeMap<u64, Job>,
    cache: VecDeque<(String, Value, usize)>,
}
fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(State::default()))
}
fn snapshot(id: u64, job: &Job) -> Value {
    json!({"job_id":id,"phase":job.phase,"result":job.result,"error":job.error})
}
pub(crate) fn run(service: &ImportService, value: Value) -> Result<String, ApiError> {
    let response = match value["action"].as_str() {
        Some("catalog") => crate::rule_catalog::catalog(),
        Some("start") => {
            let publication: publication_resources::Request =
                serde_json::from_value(value["publication"].clone())
                    .map_err(|_| error("invalid_publication_request"))?;
            let pipeline = value["cleanup_pipeline"].clone();
            if !pipeline.is_array() || pipeline.as_array().is_some_and(|v| v.len() > 32) {
                return Err(error("review_cleanup_rule"));
            }
            let source = service.source(&publication.source_id, publication.revision)?;
            // serde_json objects are ordered maps: key order from Dart does not affect this hash.
            let context = value.clone();
            let key = digest(
                serde_json::to_string(&json!([
                    2,
                    value["publication"],
                    pipeline,
                    value["reference_catalog"],
                    value["preflight"]
                ]))
                .expect("cache key")
                .as_bytes(),
            );
            let mut shared = state().lock().expect("statistics state");
            let cached = shared
                .cache
                .iter()
                .find(|(k, _, _)| k == &key)
                .map(|(_, v, _)| v.clone());
            if cached.is_none()
                && shared
                    .jobs
                    .values()
                    .filter(|j| matches!(j.phase, "running" | "cancelling"))
                    .count()
                    >= 2
            {
                return Err(error("statistics_busy"));
            }
            // Forgotten terminal handles must not accumulate indefinitely.
            while shared.jobs.len() >= 16 {
                let id = shared
                    .jobs
                    .iter()
                    .find(|(_, j)| !matches!(j.phase, "running" | "cancelling"))
                    .map(|(id, _)| *id)
                    .expect("terminal job");
                shared.jobs.remove(&id);
            }
            shared.sequence += 1;
            let id = shared.sequence;
            let cancel = Arc::new(AtomicBool::new(false));
            let mut job = Job {
                cancel: Arc::clone(&cancel),
                released: false,
                phase: "running",
                result: None,
                error: None,
            };
            if let Some(mut result) = cached {
                result["cache_hit"] = json!(true);
                job.phase = "completed";
                job.result = Some(result);
            }
            let response = snapshot(id, &job);
            let needs_worker = job.result.is_none();
            shared.jobs.insert(id, job);
            drop(shared);
            if needs_worker {
                let spawn = std::thread::Builder::new()
                    .name(format!("rule-statistics-{id}"))
                    .spawn(move || {
                        let result =
                            calculate(&source, publication, pipeline, &cancel).and_then(|mut r| {
                                enrich(&source, &context, &mut r)?;
                                Ok(r)
                            });
                        let mut shared = state().lock().expect("statistics state");
                        let Some(job) = shared.jobs.get_mut(&id) else {
                            return;
                        };
                        if job.released {
                            shared.jobs.remove(&id);
                            return;
                        }
                        if cancel.load(Ordering::Relaxed) {
                            job.phase = "cancelled";
                            return;
                        }
                        match result {
                            Ok(mut result) => {
                                result["config_fingerprint"] = json!(key);
                                result["cache_hit"] = json!(false);
                                job.phase = "completed";
                                job.result = Some(result.clone());
                                let bytes = serde_json::to_vec(&result).expect("statistics").len();
                                if bytes <= 4 * 1024 * 1024 {
                                    shared.cache.retain(|(k, _, _)| k != &key);
                                    shared.cache.push_back((key, result, bytes));
                                    while shared.cache.len() > 4
                                        || shared.cache.iter().map(|(_, _, n)| n).sum::<usize>()
                                            > 8 * 1024 * 1024
                                    {
                                        shared.cache.pop_front();
                                    }
                                }
                            }
                            Err(e) => {
                                job.phase = "failed";
                                job.error = Some(json!({"reason":e.next_action}));
                            }
                        }
                    });
                if spawn.is_err() {
                    state().lock().expect("statistics state").jobs.remove(&id);
                    return Err(error("statistics_worker_unavailable"));
                }
            }
            response
        }
        Some(action @ ("poll" | "cancel" | "release")) => {
            let id = value["job_id"]
                .as_u64()
                .ok_or_else(|| error("statistics_job_missing"))?;
            let mut shared = state().lock().expect("statistics state");
            let job = shared
                .jobs
                .get_mut(&id)
                .ok_or_else(|| error("statistics_job_missing"))?;
            if matches!(action, "cancel" | "release") && job.phase == "running" {
                job.cancel.store(true, Ordering::Relaxed);
                job.phase = "cancelling";
            }
            let response = snapshot(id, job);
            if action == "release" {
                if matches!(job.phase, "running" | "cancelling") {
                    // Keep the worker in the concurrency count until it has actually exited.
                    job.released = true;
                } else {
                    shared.jobs.remove(&id);
                }
            }
            response
        }
        _ => return Err(error("unknown_statistics_action")),
    };
    Ok(response.to_string())
}

#[cfg(test)]
#[path = "rule_statistics_tests.rs"]
mod tests;

pub(crate) fn enrich(
    source: &SourceSnapshot,
    context: &Value,
    result: &mut Value,
) -> Result<(), ApiError> {
    let request: publication_resources::Request =
        serde_json::from_value(context["publication"].clone())
            .map_err(|_| error("invalid_publication_request"))?;
    let (book, settings) = publication_resources::compose(source, request)?;
    let rows = result["rules"].as_array_mut().unwrap();
    if context["reference_catalog"].is_object() {
        let catalog: crate::catalog::Catalog =
            serde_json::from_value(context["reference_catalog"].clone())
                .map_err(|_| error("invalid_catalog"))?;
        crate::catalog::validate_snapshot(&catalog)?;
        let view = SourceSnapshot::for_effective_diagnostics(&book)?;
        let locations = Locations {
            book: &book,
            lines: view.decoded_line_ranges(),
        };
        let mut positions: BTreeMap<&str, Vec<Value>> = BTreeMap::new();
        let local: Vec<_> = book
            .tree
            .nodes
            .iter()
            .filter(|n| {
                n.role == easypub_core::structure::Role::Chapter
                    || n.role == easypub_core::structure::Role::Section
            })
            .collect();
        let reference: Vec<_> = catalog
            .entries
            .iter()
            .filter(|e| !e.structural_volume)
            .collect();
        let mut used = std::collections::BTreeSet::new();
        let (mut extra, mut titles, mut order, mut last) = (0usize, 0usize, 0usize, None);
        for n in &local {
            let exact: Vec<_> = reference
                .iter()
                .enumerate()
                .filter(|(i, e)| !used.contains(i) && e.title.trim() == n.title.trim())
                .map(|(i, _)| i)
                .collect();
            let number = easypub_core::chapter_rules::generic_number(&n.title);
            let numbered: Vec<_> = reference
                .iter()
                .enumerate()
                .filter(|(i, e)| {
                    !used.contains(i)
                        && number.is_some()
                        && easypub_core::chapter_rules::generic_number(&e.title) == number
                })
                .map(|(i, _)| i)
                .collect();
            let matched = if exact.len() == 1 {
                Some((exact[0], false))
            } else if numbered.len() == 1 {
                Some((numbered[0], true))
            } else {
                None
            };
            if let Some((i, different)) = matched {
                used.insert(i);
                titles += usize::from(different);
                order += usize::from(last.is_some_and(|j| i < j));
                for (id, hit) in [("title", different), ("order", last.is_some_and(|j| i < j))] {
                    if hit && positions.entry(id).or_default().len() < 50 {
                        positions.get_mut(id).unwrap().push(locations.byte(n.start));
                    }
                }
                last = Some(i);
            } else {
                extra += 1;
                if positions.entry("extra").or_default().len() < 50 {
                    positions
                        .get_mut("extra")
                        .unwrap()
                        .push(locations.byte(n.start));
                }
            }
        }
        for (id, count) in [
            ("missing", reference.len() - used.len()),
            ("extra", extra),
            ("title", titles),
            ("order", order),
        ] {
            let row = rows
                .iter_mut()
                .find(|r| r["id"] == format!("catalog_check.{id}"))
                .unwrap();
            row["status"] = json!("complete");
            row["count"] = json!(count);
            row["locations"] = json!(positions.remove(id).unwrap_or_default());
            row["reason"] = Value::Null;
        }
    }
    if let Some(preflight) = context["preflight"].as_object() {
        for (id, count) in preflight {
            if let Some(row) = rows
                .iter_mut()
                .find(|r| r["id"] == format!("preflight.{id}"))
                && count.is_u64()
            {
                row["count"] = count.clone();
                row["status"] = json!("complete");
                row["reason"] = Value::Null;
            }
        }
    }
    for row in rows {
        if row["status"] == "unavailable" {
            row["count"] = Value::Null;
        }
        if row["id"]
            .as_str()
            .is_some_and(|id| id.starts_with("catalog_check.") || id.starts_with("preflight."))
        {
            row["enabled"] = json!(settings.rule_options.enabled(row["id"].as_str().unwrap()));
            row["hypothetical"] = json!(row["enabled"] == false && row["status"] == "complete");
        }
    }
    Ok(())
}
