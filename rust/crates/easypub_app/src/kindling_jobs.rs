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
        // 同时进行的转换最多 8 个（V38，OUT-083：设置“同时处理的书”的最大档位）。
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
