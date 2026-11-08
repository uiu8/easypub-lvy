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
            let result = fetch();
            *flight.result.lock().unwrap() = Some(result.clone());
            flight.ready.notify_all();
            self.0.lock().unwrap().remove(&key);
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
