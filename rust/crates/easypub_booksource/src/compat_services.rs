//! 书源宿主服务：匿名标识与显式协商的用户交互，不持久化登录字段。
use ring::rand::{SecureRandom, SystemRandom};
use serde_json::Value;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

type Interaction = Arc<dyn Fn(&str, Value) -> Result<Value, String> + Send + Sync>;
#[derive(Default)]
pub struct Services {
    pub data_dir: Mutex<Option<PathBuf>>,
    pub interaction: Mutex<Option<Interaction>>,
    pub explore_revision: AtomicU64,
    recent_actions: Mutex<HashMap<&'static str, Instant>>,
}
impl Services {
    pub fn connected(&self) -> bool {
        self.interaction.lock().unwrap().is_some()
    }
    pub fn request(&self, kind: &str, value: Value) -> Result<Value, String> {
        let context = crate::control::current();
        context.check()?;
        if !context.interactive {
            return Err("当前任务不允许用户交互".into());
        }
        let handler = self
            .interaction
            .lock()
            .unwrap()
            .clone()
            .ok_or("界面尚未连接书源交互，请从书源登录入口操作")?;
        handler(kind, value)
    }
    pub fn action(&self, kind: &'static str, mut payload: Value) -> Result<bool, String> {
        let context = crate::control::current();
        context.check()?;
        if kind == "explore_refresh" && context.exploring {
            return Ok(false);
        }
        if !context.interactive {
            return Err("当前任务不允许用户交互".into());
        }
        // 按书源、按动作节流；不保存提示/剪贴板文字。
        {
            let mut recent = self.recent_actions.lock().unwrap();
            if recent
                .get(kind)
                .is_some_and(|last| last.elapsed() < Duration::from_secs(1))
            {
                return Ok(false);
            }
            recent.insert(kind, Instant::now());
        }
        if kind == "explore_refresh" {
            if !self.connected() {
                return Err("发现页尚未连接刷新事件".into());
            }
            payload["revision"] = (self.explore_revision.fetch_add(1, Ordering::SeqCst) + 1).into();
        }
        let reply = self.request(kind, payload)?;
        reply
            .as_bool()
            .ok_or_else(|| "界面动作需要布尔确认，不能把排队当作完成".into())
    }
    pub fn device_id(&self) -> Result<String, String> {
        static LOCK: Mutex<()> = Mutex::new(());
        let _guard = LOCK.lock().unwrap();
        let dir = self
            .data_dir
            .lock()
            .unwrap()
            .clone()
            .ok_or("匿名设备标识需要插件数据目录")?;
        let path = dir.join("anonymous-device-id.txt");
        match std::fs::read_to_string(&path) {
            Ok(value) if value.len() == 32 && value.bytes().all(|b| b.is_ascii_hexdigit()) => {
                return Ok(value);
            }
            Ok(_) => return Err("匿名设备标识损坏，请保留数据目录检查".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("无法读取匿名设备标识".into()),
        }
        let mut bytes = [0; 16];
        SystemRandom::new()
            .fill(&mut bytes)
            .map_err(|_| "无法生成匿名设备标识")?;
        let id = hex::encode(bytes);
        std::fs::create_dir_all(&dir).map_err(|_| "无法创建插件数据目录")?;
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|_| "匿名设备标识已由其他进程创建或无法写入，请重试")?;
        file.write_all(id.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|_| "无法保存匿名设备标识")?;
        Ok(id)
    }
}
