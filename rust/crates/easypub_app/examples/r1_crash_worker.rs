use easypub_app::transaction::{InjectFault, apply_new_file, recover};
fn main() {
    let args: Vec<_> = std::env::args().collect();
    let result = if args[1] == "recover" {
        recover(&args[2])
    } else {
        apply_new_file(&args[2], &args[3], InjectFault::None)
    };
    match result {
        Ok(report) => println!("{}", serde_json::to_string(&report).unwrap()),
        Err(error) => {
            println!("{:?}", error);
            std::process::exit(2);
        }
    }
}
