//! Small bounded registry; terminal results remain until explicitly released.
use crate::{
    kindling_export::{self, Control},
    sessions::ImportService,
};
use easypub_core::{ApiError, ErrorCode, source::SourceSnapshot};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{Arc, Mutex},
};
// 每次调用只反序列化一个请求，变体大小差异不影响内存占用。
#[allow(clippy::large_enum_variant)]
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    HistoryCoverThumbnail {
        path: String,
        crop: Option<crate::assets::Crop>,
    },
    HistoryRecoveryPreview {
        directory: String,
        task_id: String,
    },
    HistoryRecover {
        directory: String,
        task_id: String,
        token: String,
        confirmed: bool,
    },
    HistoryInspect {
        directory: String,
        task_id: String,
    },
    HistoryVerify {
        directory: String,
        task_id: String,
    },
    Start {
        request: Value,
    },
    StartEpub {
        request: Value,
    },
    Status {
        job_id: u64,
    },
    Cancel {
        job_id: u64,
    },
    Forget {
        job_id: u64,
    },
    HistoryLoad {
        directory: String,
    },
    HistorySave {
        directory: String,
        record: crate::output_history::Record,
        #[serde(default)]
        clean_completed: bool,
    },
}
struct Job {
    control: Control,
    result: Mutex<Option<Result<Value, ApiError>>>,
}
#[derive(Default)]
struct Registry {
    next: u64,
    jobs: BTreeMap<u64, Arc<Job>>,
}
#[derive(Default)]
pub struct Manager {
    registry: Mutex<Registry>,
}
fn error(code: ErrorCode, action: &str) -> ApiError {
    ApiError::new(code, "kindling_jobs", action)
}
impl Manager {
    pub fn start(
        &self,
        source: Arc<SourceSnapshot>,
        request: kindling_export::Request,
    ) -> Result<u64, ApiError> {
        self.start_worker(move |control| kindling_export::execute(&source, request, control))
    }

    fn start_worker(&self, work: impl FnOnce(&Control) -> Result<Value, ApiError> + Send + 'static) -> Result<u64, ApiError> {
        let mut registry = self.registry.lock().unwrap();
        // 同时进行的转换最多 8 个（设置“同时处理的书”的最大档位）。
        if registry.jobs.len() >= 32
            || registry
                .jobs
                .values()
                .filter(|job| job.result.lock().unwrap().is_none())
                .count()
                >= crate::sessions::MAX_ACTIVE_JOBS
        {
            return Err(error(
                ErrorCode::Busy,
                "wait_for_export_or_release_finished_jobs",
            ));
        }
        registry.next = registry
            .next
            .checked_add(1)
            .ok_or_else(|| error(ErrorCode::TooLarge, "restart_application"))?;
        let id = registry.next;
        let job = Arc::new(Job {
            control: Control::default(),
            result: Mutex::new(None),
        });
        let worker = job.clone();
        std::thread::Builder::new()
            .name(format!("kindling-{id}"))
            .spawn(move || {
                let result = catch_unwind(AssertUnwindSafe(|| {
                    work(&worker.control)
                }))
                .unwrap_or_else(|_| Err(error(ErrorCode::Internal, "review_export_log")));
                *worker.result.lock().unwrap() = Some(result);
                worker.control.signal.notify();
            })
            .map_err(|_| error(ErrorCode::Io, "retry_export_worker"))?;
        registry.jobs.insert(id, job);
        Ok(id)
    }
    fn job(&self, id: u64) -> Result<Arc<Job>, ApiError> {
        self.registry
            .lock()
            .unwrap()
            .jobs
            .get(&id)
            .cloned()
            .ok_or_else(|| error(ErrorCode::NotFound, "refresh_export_jobs"))
    }
    pub fn status(&self, id: u64) -> Result<Value, ApiError> {
        let job = self.job(id)?;
        let result = job.result.lock().unwrap();
        let mut snapshot = job.control.snapshot();
        snapshot["job_id"] = json!(id);
        snapshot["terminal"] = json!(result.is_some());
        if let Some(value) = result.as_ref() {
            snapshot["cancellable"] = json!(false);
            match value {
                Ok(value) => snapshot["result"] = value.clone(),
                Err(e) => {
                    snapshot["phase"] = json!(if e.code == ErrorCode::Cancelled {
                        "cancelled"
                    } else {
                        "failed"
                    });
                    snapshot["error"] = json!({"code":format!("{:?}",e.code),"operation":e.operation,"next_action":e.next_action});
                }
            }
        }
        Ok(snapshot)
    }
    /// 推送任务状态（桥接第 1 批）：状态一变就调用 `emit`，到终态或 `emit` 返回 false
    /// （界面已不再监听）为止。只有内容变化才送出；任务被释放（forget）时也结束。
    pub fn watch(&self, id: u64, mut emit: impl FnMut(&Value) -> bool) -> Result<(), ApiError> {
        let job = self.job(id)?;
        let mut last: Option<Value> = None;
        loop {
            let seen = job.control.signal.version();
            let snapshot = match self.status(id) {
                Ok(snapshot) => snapshot,
                Err(e) if e.code == ErrorCode::NotFound => return Ok(()),
                Err(e) => return Err(e),
            };
            let terminal = snapshot["terminal"] == json!(true);
            if last.as_ref() != Some(&snapshot) {
                if !emit(&snapshot) {
                    return Ok(());
                }
                last = Some(snapshot);
            }
            if terminal {
                return Ok(());
            }
            job.control
                .signal
                .wait_after(seen, std::time::Duration::from_millis(500));
        }
    }
    pub fn cancel(&self, id: u64) -> Result<bool, ApiError> {
        let job = self.job(id)?;
        if job.result.lock().unwrap().is_some() {
            return Ok(false);
        }
        Ok(job.control.cancel())
    }
    pub fn forget(&self, id: u64) -> Result<(), ApiError> {
        let mut registry = self.registry.lock().unwrap();
        let job = registry
            .jobs
            .get(&id)
            .ok_or_else(|| error(ErrorCode::NotFound, "refresh_export_jobs"))?;
        if job.result.lock().unwrap().is_none() {
            return Err(error(ErrorCode::Busy, "wait_for_export_to_finish"));
        }
        registry.jobs.remove(&id);
        Ok(())
    }
    pub fn handle(&self, service: &ImportService, request: &str) -> Result<String, ApiError> {
        if request.len() > 4 * 1024 * 1024 {
            return Err(error(ErrorCode::TooLarge, "reduce_export_request"));
        }
        let command: Command = serde_json::from_str(request)
            .map_err(|_| error(ErrorCode::InvalidRule, "review_export_request"))?;
        Ok(match command {
            Command::HistoryRecoveryPreview { directory, task_id } => {
                crate::output_history::recovery_preview(std::path::Path::new(&directory), &task_id)?
            }
            Command::HistoryRecover {
                directory,
                task_id,
                token,
                confirmed,
            } => crate::output_history::recover_output(
                std::path::Path::new(&directory),
                &task_id,
                &token,
                confirmed,
            )?,
            Command::HistoryCoverThumbnail { path, crop } => {
                json!({"cover_thumbnail": crate::output_history::cover_thumbnail(&path, crop.as_ref())?})
            }
            Command::HistoryInspect { directory, task_id } => {
                crate::output_history::inspect_package(std::path::Path::new(&directory), &task_id)?
            }
            Command::HistoryVerify { directory, task_id } => {
                crate::output_history::verify(std::path::Path::new(&directory), &task_id)?
            }
            Command::HistoryLoad { directory } => {
                json!({"records": crate::output_history::load(std::path::Path::new(&directory))?})
            }
            Command::HistorySave { directory, record, clean_completed } => {
                let directory = std::path::Path::new(&directory);
                crate::output_history::save(directory, &record)?;
                let cleaned = !clean_completed || record.phase != "complete"
                    || crate::output_history::clean_completed(directory, &record).is_ok();
                json!({"saved": true, "cleaned": cleaned})
            }
            Command::Start { request } => {
                let request = kindling_export::parse(&request.to_string())?;
                let source =
                    service.source(&request.publication.source_id, request.publication.revision)?;
                json!({"job_id":self.start(source,request)?})
            }
            Command::StartEpub { request } => {
                let request = crate::epub_export::parse(&request.to_string())?;
                let source = service.source(&request.publication.source_id, request.publication.revision)?;
                let id = self.start_worker(move |control| {
                    let result = crate::epub_export::execute_controlled(&source, request,
                        crate::transaction::InjectFault::None, &|phase|control.enter(phase));
                    if result.is_ok() {control.enter("completed")?;}
                    result
                })?;
                json!({"job_id":id})
            }
            Command::Status { job_id } => self.status(job_id)?,
            Command::Cancel { job_id } => json!({"accepted":self.cancel(job_id)?}),
            Command::Forget { job_id } => {
                self.forget(job_id)?;
                json!({"forgotten":true})
            }
        }
        .to_string())
    }
}
impl Drop for Manager {
    fn drop(&mut self) {
        if let Ok(registry) = self.registry.lock() {
            for job in registry.jobs.values() {
                job.control.cancel();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn watch_pushes_phase_changes_and_terminal_result() {
        // 桥接第 1 批：阶段变化立即推送，终态带结果；只在内容变化时送出。
        let manager = Manager::default();
        let (go_tx, go_rx) = std::sync::mpsc::channel::<()>();
        let id = manager
            .start_worker(move |control| {
                go_rx.recv().unwrap();
                control.enter("converting")?;
                go_rx.recv().unwrap();
                Ok(json!({"ok": true}))
            })
            .unwrap();
        let mut phases = Vec::new();
        let start = Instant::now();
        manager
            .watch(id, |snapshot| {
                phases.push(snapshot["phase"].as_str().unwrap().to_string());
                if snapshot["terminal"] != json!(true) {
                    go_tx.send(()).unwrap();
                } else {
                    assert_eq!(snapshot["result"], json!({"ok": true}));
                }
                true
            })
            .unwrap();
        assert!(start.elapsed() < Duration::from_secs(5));
        assert_eq!(phases.first().unwrap(), "preparing");
        assert!(phases.contains(&"converting".to_string()), "{phases:?}");
        manager.forget(id).unwrap();
        assert_eq!(manager.watch(id, |_| true).unwrap_err().code, ErrorCode::NotFound);
    }

    #[test]
    fn watch_reports_cancellation() {
        let manager = Manager::default();
        let id = manager
            .start_worker(|control| loop {
                control.enter("converting")?;
                std::thread::sleep(Duration::from_millis(5));
            })
            .unwrap();
        let mut last = Value::Null;
        manager
            .watch(id, |snapshot| {
                if snapshot["phase"] == json!("converting") {
                    manager.cancel(id).unwrap();
                }
                last = snapshot.clone();
                true
            })
            .unwrap();
        assert_eq!(last["phase"], json!("cancelled"));
        assert_eq!(last["terminal"], json!(true));
    }
}
