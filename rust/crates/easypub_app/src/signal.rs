//! 状态变化通知（桥接第 1 批）：后台任务每改一次状态就把版本号加一并唤醒等待者，
//! 推送线程据此把新状态送给界面，不用界面反复来问。
use std::sync::{Condvar, Mutex};
use std::time::Duration;

#[derive(Default)]
pub struct Signal {
    version: Mutex<u64>,
    changed: Condvar,
}

impl Signal {
    pub const fn new() -> Self {
        Self {
            version: Mutex::new(0),
            changed: Condvar::new(),
        }
    }

    /// 当前版本。先取版本再读状态：读完之后的任何变化都会让 [`Signal::wait_after`] 立刻返回。
    pub fn version(&self) -> u64 {
        *self.version.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn notify(&self) {
        let mut version = self.version.lock().unwrap_or_else(|e| e.into_inner());
        *version = version.wrapping_add(1);
        self.changed.notify_all();
    }

    /// 等到版本不再是 `seen`，或超时（兜底，防止漏通知时卡住）。
    pub fn wait_after(&self, seen: u64, timeout: Duration) {
        let guard = self.version.lock().unwrap_or_else(|e| e.into_inner());
        let _ = self
            .changed
            .wait_timeout_while(guard, timeout, |v| *v == seen);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::Instant;

    #[test]
    fn change_after_version_read_is_not_missed() {
        let signal = Signal::new();
        let seen = signal.version();
        signal.notify();
        let start = Instant::now();
        signal.wait_after(seen, Duration::from_secs(5));
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn waiter_wakes_on_notify_from_other_thread() {
        let signal = Arc::new(Signal::new());
        let seen = signal.version();
        let other = signal.clone();
        let t = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            other.notify();
        });
        let start = Instant::now();
        signal.wait_after(seen, Duration::from_secs(5));
        assert!(start.elapsed() < Duration::from_secs(2));
        t.join().unwrap();
    }

    #[test]
    fn times_out_without_change() {
        let signal = Signal::new();
        let start = Instant::now();
        signal.wait_after(signal.version(), Duration::from_millis(30));
        assert!(start.elapsed() >= Duration::from_millis(25));
    }
}
