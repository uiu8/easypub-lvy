//! 只合并正在进行的同章请求，不持久化正文，也不把错误缓存成成功。
use std::{
    collections::HashMap,
    sync::{Arc, Condvar, Mutex},
    time::Duration,
};
#[derive(Default)]
pub struct Flights(Mutex<HashMap<String, Arc<Flight>>>);
#[derive(Default)]
struct Flight {
    result: Mutex<Option<Result<String, String>>>,
    ready: Condvar,
}
impl Flights {
    pub fn run(
        &self,
        key: String,
        fetch: impl FnOnce() -> Result<String, String>,
    ) -> Result<String, String> {
        let (flight, owner) = {
            let mut map = self.0.lock().unwrap();
            if let Some(f) = map.get(&key) {
                (f.clone(), false)
            } else {
                let f = Arc::new(Flight::default());
                map.insert(key.clone(), f.clone());
                (f, true)
            }
        };
        if owner {
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(fetch));
            let result = match &outcome {
                Ok(result) => result.clone(),
                Err(_) => Err("合并请求异常终止，请重试".to_owned()),
            };
            *flight.result.lock().unwrap() = Some(result.clone());
            flight.ready.notify_all();
            self.0.lock().unwrap().remove(&key);
            if let Err(payload) = outcome {
                std::panic::resume_unwind(payload);
            }
            result
        } else {
            let mut result = flight.result.lock().unwrap();
            loop {
                crate::control::current().check()?;
                if let Some(r) = &*result {
                    return r.clone();
                }
                result = flight
                    .ready
                    .wait_timeout(result, Duration::from_millis(100))
                    .unwrap()
                    .0;
            }
        }
    }
}

#[cfg(test)]
#[test]
fn owner_panic_wakes_waiter_and_allows_retry() {
    use std::sync::mpsc;
    let flights = Arc::new(Flights::default());
    let (started, ready) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let owner_flights = flights.clone();
    let owner = std::thread::spawn(move || {
        std::panic::catch_unwind(|| {
            owner_flights.run("chapter".into(), || {
                started.send(()).unwrap();
                released.recv().unwrap();
                panic!("synthetic owner failure");
            })
        })
    });
    ready.recv_timeout(Duration::from_secs(5)).unwrap();
    let (done, result) = mpsc::channel();
    let waiter_flights = flights.clone();
    let waiter = std::thread::spawn(move || {
        done.send(waiter_flights.run("chapter".into(), || panic!("must share owner")))
            .unwrap();
    });
    // 确认真实等待者已取得同一 Flight，避免仅测试 owner 完成后的另一次请求。
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while Arc::strong_count(flights.0.lock().unwrap().get("chapter").unwrap()) < 3 {
        assert!(std::time::Instant::now() < deadline, "waiter did not join");
        std::thread::yield_now();
    }
    release.send(()).unwrap();
    assert_eq!(
        result.recv_timeout(Duration::from_secs(5)).unwrap(),
        Err("合并请求异常终止，请重试".into())
    );
    assert!(owner.join().unwrap().is_err());
    waiter.join().unwrap();
    assert!(flights.0.lock().unwrap().is_empty());
    assert_eq!(
        flights
            .run("chapter".into(), || Ok("retry".into()))
            .unwrap(),
        "retry"
    );
}
