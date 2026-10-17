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
mod cleanup;
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

#[derive(Serialize)]
struct Statistic {
    id: String,
    enabled: bool,
    count: usize,
    unit: &'static str,
    status: &'static str,
    locations: Vec<Value>,
    changed_ranges: Vec<(u32, u32)>,
    candidate_ranges: Vec<(u32, u32)>,
    invalid_count: usize,
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

fn calculate(
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
                    count: 0,
                    unit,
                    status: "complete",
                    locations: vec![],
                    changed_ranges: vec![],
                    candidate_ranges: vec![],
                    invalid_count: 0,
                    reason: None,
                },
            )
        })
        .collect();
    recognition::collect(&view, &locations, &mut stats, cancel)?;
    checkpoint(cancel)?;
    cleanup::collect(&view, &pipeline, &locations, &mut stats, cancel)?;
    checkpoint(cancel)?;
    layout::collect(&book, &settings, &locations, &mut stats, cancel)?;
    checkpoint(cancel)?;
    Ok(
        json!({"schema":1,"read_only":true,"content_id":digest(book.text.as_bytes()),
        "source_id":source.summary().source_id,"revision":source.summary().revision,
        "byte_length":book.text.len(),"line_count":locations.lines.len(),"chapter_count":book.tree.nodes.len(),
        "elapsed_ms":started.elapsed().as_secs_f64()*1000.0,"rules":stats.into_values().collect::<Vec<_>>() }),
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
            let key = digest(
                serde_json::to_string(&json!([1, value["publication"], pipeline]))
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
                        let result = calculate(&source, publication, pipeline, &cancel);
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
