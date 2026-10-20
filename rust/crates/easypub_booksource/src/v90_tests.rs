use crate::{
    control::{Context, ErrorKind, Profile},
    engine::{Engine, SourceRt},
    source::BookSource,
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

#[test]
fn initialization_is_cancellable_and_native_errors_keep_causes_without_secrets() {
    let cancel = Arc::new(AtomicBool::new(false));
    let worker = cancel.clone();
    let start = Instant::now();
    let thread = std::thread::spawn(move || {
        let _guard = Context::new(Profile::Content, worker).enter();
        let source = BookSource {
            js_lib: "while(true){}".into(),
            ..Default::default()
        };
        Engine::new(SourceRt::new(source)).map(|_| ())
    });
    std::thread::sleep(Duration::from_millis(40));
    cancel.store(true, Ordering::Relaxed);
    let _ = thread.join().unwrap();
    assert!(
        start.elapsed() < Duration::from_secs(2),
        "JS 库初始化必须响应任务取消"
    );
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
