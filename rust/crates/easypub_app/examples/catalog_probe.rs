use easypub_app::{catalog, sessions::ImportService};
use serde_json::json;

fn main() {
    let cookie = std::env::var("EASYPUB_QIDIAN_COOKIE").unwrap_or_default();
    let service = ImportService::new().expect("service");
    for id in ["1037068020", "1037632698", "1010868264", "1035548629"] {
        let request = json!({"op":"acquire","source":"qidian","input":format!("https://www.qidian.com/book/{id}/"),"use_cache":false});
        let value = catalog::execute(&service, &request.to_string(), &cookie)
            .unwrap_or_else(|e| json!({"error":format!("{:?}",e.code),"reason":e.next_action}));
        println!("{}", json!({"book_id":id,"result":value}));
    }
}
