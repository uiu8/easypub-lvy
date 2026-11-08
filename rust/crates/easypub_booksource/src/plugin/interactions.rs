//! 界面主动协商后才启用；回复按随机请求 ID 与书源 ID 配对。
use super::*;
use ring::rand::{SecureRandom, SystemRandom};
use std::{sync::mpsc, time::Instant};
struct Pending {
    source: String,
    sender: mpsc::SyncSender<Result<Value, String>>,
}
static PENDING: OnceLock<Mutex<HashMap<String, Pending>>> = OnceLock::new();
fn pending() -> &'static Mutex<HashMap<String, Pending>> {
    PENDING.get_or_init(Default::default)
}
struct Cleanup(String);
impl Drop for Cleanup {
    fn drop(&mut self) {
        pending().lock().unwrap().remove(&self.0);
    }
}

fn request(source: &str, kind: &str, payload: Value) -> Result<Value, String> {
    let mut bytes = [0; 16];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| "无法创建交互请求")?;
    let request_id = hex::encode(bytes);
    let (sender, receiver) = mpsc::sync_channel(1);
    {
        let mut map = pending().lock().unwrap();
        if map.len() >= 32 {
            return Err("等待中的书源交互过多，请先处理现有窗口".into());
        }
        map.insert(
            request_id.clone(),
            Pending {
                source: source.into(),
                sender,
            },
        );
    }
    let _cleanup = Cleanup(request_id.clone());
    send(
        json!({"event":"source.interaction","source_id":source,"request_id":request_id,"kind":kind,"payload":payload,"timeout_ms":120000}),
    );
    let result = (|| {
        let until = Instant::now() + Duration::from_secs(120);
        loop {
            crate::control::current().check()?;
            if Instant::now() >= until {
                return Err("书源交互超时".into());
            }
            match receiver.recv_timeout(Duration::from_millis(40)) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Disconnected) => return Err("书源交互已关闭".into()),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
        }
    })();
    send(json!({"event":"source.interaction.closed","source_id":source,"request_id":request_id}));
    result
}

pub(super) fn handle(method: &str, params: &Value) -> Result<Value, String> {
    let id: String = param(params, "id")?;
    match method {
        "source.interaction.enable" => {
            let enabled: bool = param(params, "enabled")?;
            let capabilities: Vec<String> = if params.get("capabilities").is_some() {
                param(params, "capabilities")?
            } else {
                vec![]
            };
            if capabilities.iter().any(|c| {
                !matches!(
                    c.as_str(),
                    "notice" | "clipboard" | "explore_refresh" | "book_search" | "login_open"
                )
            }) {
                return Err("不支持的书源交互能力".into());
            }
            let rt = runtime(&id)?;
            *rt.services.interaction.lock().unwrap() = if enabled {
                {
                    let source_id = id.clone();
                    Some(Arc::new(move |kind, value| {
                        if !matches!(kind, "verification" | "login_data" | "login_refresh")
                            && !capabilities.iter().any(|c| c == kind)
                        {
                            return Err("界面尚未连接这个书源动作".into());
                        }
                        request(&source_id, kind, value)
                    }))
                }
            } else {
                None
            };
            if !enabled {
                let mut map = pending().lock().unwrap();
                map.retain(|_, item| {
                    if item.source == id {
                        let _ = item.sender.try_send(Err("已取消".into()));
                        false
                    } else {
                        true
                    }
                });
            }
            Ok(json!({"enabled":enabled}))
        }
        "source.interaction.reply" => {
            let request_id: String = param(params, "request_id")?;
            let value = params.get("value").cloned().unwrap_or(Value::Null);
            if value.to_string().len() > 65536 {
                return Err("交互回复超过 64KiB".into());
            }
            let mut map = pending().lock().unwrap();
            let item = map.get(&request_id).ok_or("交互请求已结束或不存在")?;
            if item.source != id {
                return Err("交互请求不属于这个书源".into());
            }
            let item = map.remove(&request_id).unwrap();
            let result = if params["cancel"].as_bool() == Some(true) {
                Err("已取消".into())
            } else {
                Ok(value)
            };
            item.sender.try_send(result).map_err(|_| "交互请求已结束")?;
            Ok(json!({"ok":true}))
        }
        _ => Err("未知书源交互方法".into()),
    }
}

#[cfg(test)]
pub(in crate::plugin) mod tests {
    use super::*;
    pub(in crate::plugin) fn reply_is_scoped_single_use_and_timeout_cleans_up() {
        let worker = std::thread::spawn(|| request("fixture-interaction", "login_data", json!({})));
        let until = Instant::now() + Duration::from_secs(2);
        let key = loop {
            if let Some(key) = pending()
                .lock()
                .unwrap()
                .iter()
                .find(|(_, v)| v.source == "fixture-interaction")
                .map(|(k, _)| k.clone())
            {
                break key;
            }
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(5));
        };
        assert!(
            handle(
                "source.interaction.reply",
                &json!({"id":"other", "request_id":key, "value":"wrong"})
            )
            .is_err()
        );
        handle(
            "source.interaction.reply",
            &json!({"id":"fixture-interaction", "request_id":key, "value":{"user":"synthetic"}}),
        )
        .unwrap();
        assert_eq!(worker.join().unwrap().unwrap(), json!({"user":"synthetic"}));
        assert!(
            handle(
                "source.interaction.reply",
                &json!({"id":"fixture-interaction", "request_id":key})
            )
            .is_err()
        );
        let mut context = crate::control::current();
        context.deadline = Some(Instant::now() + Duration::from_millis(40));
        let _guard = context.enter();
        assert!(
            request("fixture-timeout", "verification", json!({}))
                .unwrap_err()
                .contains("超时")
        );
        assert!(
            !pending()
                .lock()
                .unwrap()
                .values()
                .any(|v| v.source == "fixture-timeout")
        );
    }
}
