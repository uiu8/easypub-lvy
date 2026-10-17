//! Isolated Windows release probe. Not whole-app memory or conversion semantics.
use std::{alloc::{GlobalAlloc, Layout, System}, sync::atomic::{AtomicUsize, Ordering}};

struct CountingAllocator;
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
fn add(bytes: usize) {
    let live = LIVE.fetch_add(bytes, Ordering::Relaxed) + bytes;
    PEAK.fetch_max(live, Ordering::Relaxed);
}
unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc(layout) };
        if !ptr.is_null() { add(layout.size()); }
        ptr
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = unsafe { System.alloc_zeroed(layout) };
        if !ptr.is_null() { add(layout.size()); }
        ptr
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) };
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        let next = unsafe { System.realloc(ptr, layout, size) };
        if !next.is_null() {
            LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
            add(size);
        }
        next
    }
}
#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

#[repr(C)]
#[derive(Default)]
struct Memory {
    cb: u32, faults: u32, peak_working_set: usize, working_set: usize,
    peak_paged: usize, paged: usize, peak_nonpaged: usize, nonpaged: usize,
    pagefile: usize, peak_pagefile: usize, private_bytes: usize,
}
#[link(name="kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> *mut std::ffi::c_void;
    fn K32GetProcessMemoryInfo(process: *mut std::ffi::c_void, counters: *mut Memory, size: u32) -> i32;
}
fn sample(stage: &str, elapsed_ms: f64) {
    let mut memory = Memory { cb: size_of::<Memory>() as u32, ..Default::default() };
    assert_ne!(unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut memory, size_of::<Memory>() as u32) }, 0);
    let live = LIVE.load(Ordering::Relaxed);
    let peak = PEAK.load(Ordering::Relaxed);
    println!("{{\"stage\":\"{stage}\",\"rust_live_bytes\":{live},\"rust_peak_bytes\":{peak},\"private_bytes\":{},\"working_set_bytes\":{},\"peak_working_set_bytes\":{},\"elapsed_ms\":{elapsed_ms}}}", memory.private_bytes, memory.working_set, memory.peak_working_set);
}
fn reset_peak() { PEAK.store(LIVE.load(Ordering::Relaxed), Ordering::Relaxed); }

fn main() {
    // Initialize stdout before baseline so its buffer is not attributed to dictionaries.
    println!("{{\"probe\":\"ferrous-opencc-0.4.0\",\"dictionary_enabled\":{}}}", cfg!(feature="dictionary"));
    sample("before_init", 0.0);
    #[cfg(feature="dictionary")]
    {
        use ferrous_opencc::{OpenCC, config::BuiltinConfig};
        use std::time::Instant;
        let reversed = std::env::args().nth(1).as_deref() == Some("reverse");
        let (first, second) = if reversed { (BuiltinConfig::T2s, BuiltinConfig::S2t) } else { (BuiltinConfig::S2t, BuiltinConfig::T2s) };
        let start = Instant::now();
        let a = OpenCC::from_config(first).unwrap();
        sample(if reversed {"t2s_loaded"} else {"s2t_loaded"}, start.elapsed().as_secs_f64()*1000.0);
        let start = Instant::now();
        let b = OpenCC::from_config(second).unwrap();
        sample("both_loaded", start.elapsed().as_secs_f64()*1000.0);
        let s2t = if reversed { &b } else { &a };
        assert_eq!(s2t.convert("头发发展，皇后后来，干燥干活。"), "頭髮發展，皇后後來，乾燥幹活。");
        let line = "头发发展，皇后后来，干燥干活。ASCII 😀𠀀\r\n".repeat(8);
        let expected = s2t.convert(&line);
        reset_peak();
        let start = Instant::now();
        let mut bytes = 0usize;
        for _ in 0..20_000 {
            let output = s2t.convert(&line);
            assert_eq!(output, expected);
            bytes += output.len();
            std::hint::black_box(&output);
        }
        sample("after_20000_lines", start.elapsed().as_secs_f64()*1000.0);
        println!("{{\"fixture_input_bytes\":{},\"fixture_output_bytes\":{bytes},\"line_bytes\":{},\"source_retained_whole\":false}}", line.len()*20_000, line.len());
        std::hint::black_box((&a, &b));
    }
}
