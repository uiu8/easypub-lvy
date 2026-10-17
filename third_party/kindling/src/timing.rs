pub fn phase(label: &str) {
    use std::sync::Mutex;
    use std::time::Instant;
    static LAST: Mutex<Option<Instant>> = Mutex::new(None);
    if std::env::var_os("KINDLING_PROFILE").is_none() {
        return;
    }
    let mut last = LAST.lock().unwrap();
    let now = Instant::now();
    match *last {
        Some(p) => eprintln!(
            "[profile] {:>8.0} ms  {label}",
            (now - p).as_secs_f64() * 1000.0
        ),
        None => eprintln!("[profile]   start     {label}"),
    }
    *last = Some(now);
}
