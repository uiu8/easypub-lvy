//! Component costs complement end-to-end Flutter and rendered frame probes.
//! Run after builds/tests finish; inputs are read only. Filesystem samples are
//! OS-cache-warm reads, not a claim about cold-disk speed.
use easypub_core::{publication::compose, source::{SourceSnapshot, RULE_ID}, structure::Structure};
use serde_json::{Value, json};
use std::{collections::BTreeMap, time::Instant};

fn record<T>(samples: &mut BTreeMap<&'static str, Vec<f64>>, key: &'static str, action: impl FnOnce() -> T) -> T {
    let start = Instant::now();
    let result = action();
    samples.entry(key).or_default().push(start.elapsed().as_secs_f64() * 1000.0);
    result
}

fn main() {
    let mut cases = Vec::new();
    for path in std::env::args().skip(1) {
        let mut samples = BTreeMap::new();
        let mut bytes = 0;
        let mut node_count = 0;
        for _ in 0..5 {
            let raw = record(&mut samples,"file_read_ms",||std::fs::read(&path).unwrap());
            bytes=raw.len();
            let source=record(&mut samples,"rust_decode_index_ms",||SourceSnapshot::from_utf8(raw,RULE_ID,||false).unwrap());
            let structure=Structure::new(&source);
            let book=record(&mut samples,"rust_compose_ms",||compose(&source,&structure,None).unwrap());
            node_count=book.tree.nodes.len();
            let page=book.tree.nodes.iter().take(30).collect::<Vec<_>>();
            let serialized=record(&mut samples,"rust_json_encode_30_nodes_ms",||serde_json::to_string(&page).unwrap());
            let decoded: Value=record(&mut samples,"rust_json_decode_30_nodes_ms",||serde_json::from_str(&serialized).unwrap());
            assert_eq!(decoded.as_array().unwrap().len(),page.len());
        }
        let metrics=samples.into_iter().map(|(key,mut values)| {
            values.sort_by(f64::total_cmp);
            (key,json!({"samples_ms":values,"p50_ms":values[2],"max_ms":values[4]}))
        }).collect::<BTreeMap<_,_>>();
        cases.push(json!({"path":path,"bytes":bytes,"nodes":node_count,"metrics":metrics}));
    }
    println!("{}",json!({"scope":"Release component timings; five samples, p50/max only. Direct Rust excludes FRB codec; not subtractable from separate Flutter runs. OS-cache-warm IO.","cases":cases}));
}
