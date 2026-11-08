use crate::{
    control::{Context, ErrorKind, Profile},
    engine::{Engine, SourceRt},
    source::BookSource,
};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[test]
fn initialization_is_cancellable_and_native_errors_keep_causes_without_secrets() {
    for main_script in [false, true] {
        let cancel = Arc::new(AtomicBool::new(false));
        let _guard = Context::new(Profile::Content, cancel.clone()).enter();
        let script = "java.toast('ready'); while(true){}";
        let source = if main_script {
            BookSource {
                main_js: script.into(),
                ..Default::default()
            }
        } else {
            BookSource {
                js_lib: script.into(),
                ..Default::default()
            }
        };
        let rt = SourceRt::new(source);
        let cancelled_at = Arc::new(Mutex::new(None));
        let observed = cancelled_at.clone();
        // 从脚本内的宿主回调同步发出取消，排除线程调度和引擎启动耗时。
        // 回调正常返回，后续无限循环必须由 QuickJS 中断处理器终止。
        *rt.services.interaction.lock().unwrap() = Some(Arc::new(move |_, _| {
            *observed.lock().unwrap() = Some(Instant::now());
            cancel.store(true, Ordering::Relaxed);
            Ok(true.into())
        }));
        let error = Engine::new(rt).err().expect("初始化必须响应取消");
        let elapsed = cancelled_at
            .lock()
            .unwrap()
            .expect("初始化必须进入目标脚本")
            .elapsed();
        assert_eq!(ErrorKind::classify(&error), ErrorKind::Cancelled);
        assert!(
            elapsed < Duration::from_secs(2),
            "不能依赖 JS 自身预算退出：{elapsed:?}"
        );
    }
    let e = Engine::new(SourceRt::new(BookSource::default())).unwrap();
    e.run(|s| {
        let error = s
            .eval_js("throw new Error('EP_FAKE_COOKIE_VALUE')", &[])
            .unwrap_err();
        assert!(!error.contains("EP_FAKE_COOKIE_VALUE"));
        assert_eq!(ErrorKind::classify(&error).cause(), Some("rule"));
        let error = s
            .eval_js("java.importScript('file:///C:/secret')", &[])
            .unwrap_err();
        assert!(!error.contains("secret"));
        assert_eq!(ErrorKind::classify(&error).cause(), Some("unsupported"));
    });
}
