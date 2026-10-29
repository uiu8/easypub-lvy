//! 存储布局、受控缓存与可回滚搬家。指针固定在系统应用目录，不写凭据内容。
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};
type Result<T> = std::result::Result<T, &'static str>;
static CONTROL: Mutex<()> = Mutex::new(());
static NEXT: AtomicU64 = AtomicU64::new(1);
static ACTIVE: OnceLock<Mutex<Option<Store>>> = OnceLock::new();
static JOB: OnceLock<Mutex<Option<Job>>> = OnceLock::new();
static LEASES: OnceLock<Mutex<BTreeMap<String, File>>> = OnceLock::new();
fn active() -> &'static Mutex<Option<Store>> {
    ACTIVE.get_or_init(Default::default)
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct Config {
    data: Option<PathBuf>,
    cache: Option<PathBuf>,
    image_mode: Option<String>,
    aliases: Vec<(PathBuf, PathBuf)>,
    old_caches: Vec<(String, PathBuf)>,
    pending: Option<Pending>,
}
#[derive(Clone, Serialize, Deserialize)]
struct Pending {
    target: PathBuf,
    manifest: PathBuf,
}
#[derive(Clone, Serialize, Deserialize)]
struct Manifest {
    maps: Vec<(PathBuf, PathBuf)>,
    files: Vec<Entry>,
}
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
struct Entry {
    source: PathBuf,
    target: PathBuf,
    bytes: u64,
    hash: String,
}
#[derive(Clone)]
struct Store {
    local: PathBuf,
    temp: PathBuf,
    config: Config,
    startup_error: Option<String>,
}
struct Job {
    id: String,
    cancel: Arc<AtomicBool>,
    progress: Value,
}
const CACHE_KINDS: &[&str] = &[
    "imports",
    "generated_covers",
    "conversion_covers",
    "content_preview",
    "kindle_preview",
    "conversion_work",
    "catalog",
];
impl Store {
    fn defaults() -> Self {
        let temp = std::env::temp_dir();
        Self {
            local: std::env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|| temp.clone()),
            temp,
            config: Config::default(),
            startup_error: None,
        }
    }
    fn pointer(&self) -> PathBuf {
        self.local.join("EasyPub-RustFlutter/location.json")
    }
    fn data(&self) -> PathBuf {
        self.config
            .data
            .clone()
            .unwrap_or_else(|| self.local.join("EasyPub-RustFlutter"))
    }
    fn cache(&self) -> PathBuf {
        self.config
            .cache
            .clone()
            .unwrap_or_else(|| self.local.join("EasyPub-RustFlutter-cache"))
    }
    fn path(&self, kind: &str) -> PathBuf {
        let data = self.data();
        if CACHE_KINDS.contains(&kind)
            && let Some(root) = &self.config.cache
        {
            return root.join(kind);
        }
        match kind {
            "settings" => data.join("settings"),
            "plugins" => data.join("plugins"),
            "plugin_data" => data.join("plugin-data"),
            "assets" => data.join("assets"),
            "source_recovery" => data.join("settings/source-recovery"),
            "credentials" | "book_sources" => {
                let root = if self.config.data.is_some() {
                    data
                } else {
                    self.local.join("EasyPubRustFlutter")
                };
                root.join(if kind == "credentials" {
                    "credentials-v1"
                } else {
                    "book-sources-v1"
                })
            }
            "imports" => self.local.join("EasyPub-RustFlutter/imports"),
            "generated_covers" => data.join("settings/generated-covers"),
            "conversion_covers" => data.join("settings/conversion-covers"),
            "content_preview" => self.temp.join("EasyPub-content-preview"),
            "kindle_preview" => self.temp.join("EasyPub-kindle-preview-edge"),
            "conversion_work" => self.local.join("EasyPubPlusPlus/conversion-work"),
            "catalog" => self.local.join("EasyPubRustFlutter/catalog-v1"),
            _ => data,
        }
    }
    fn save(&self) -> Result<()> {
        atomic_json(
            &self.pointer(),
            &serde_json::to_value(&self.config).map_err(|_| "storage_invalid_config")?,
        )
    }
    fn snapshot(&self) -> Value {
        let defaults = Self {
            config: Config::default(),
            ..self.clone()
        };
        let mut categories = BTreeMap::new();
        for kind in CACHE_KINDS.iter().copied().chain([
            "settings",
            "plugins",
            "plugin_data",
            "assets",
            "credentials",
            "book_sources",
            "source_recovery",
        ]) {
            categories.insert(kind, self.path(kind));
        }
        json!({"data_root":self.data(),"cache_root":self.config.cache,"cache_layout":if self.config.cache.is_some(){"unified"}else{"legacy"},"default_data_root":defaults.data(),"default_cache_root":Value::Null,"suggested_cache_root":defaults.cache(),"paths":categories,"image_mode":self.config.image_mode.as_deref().unwrap_or("copy"),"pending_restart":self.config.pending.is_some(),"pending_data_root":self.config.pending.as_ref().map(|p|&p.target),"startup_error":self.startup_error,"output_policy":"existing_output_setting","aliases":self.config.aliases})
    }
}
pub fn path(kind: &str) -> PathBuf {
    active()
        .lock()
        .unwrap()
        .as_ref()
        .cloned()
        .unwrap_or_else(Store::defaults)
        .path(kind)
}
/// 已配置过的缓存位置，供成品记录核对旧工作目录。
pub fn cache_paths(kind: &str) -> Vec<PathBuf> {
    let store = active()
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_else(Store::defaults);
    let mut roots = vec![store.path(kind)];
    for (k, p) in &store.config.old_caches {
        if k == kind && !roots.contains(p) {
            roots.push(p.clone());
        }
    }
    let old = Store {
        config: Config::default(),
        ..store
    }
    .path(kind);
    if !roots.contains(&old) {
        roots.push(old);
    }
    roots
}
fn io(_: std::io::Error) -> &'static str {
    "storage_io_error"
}
fn linked(meta: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return true;
        }
    }
    meta.file_type().is_symlink()
}
fn no_links(path: &Path) -> Result<()> {
    for p in path.ancestors() {
        match fs::symlink_metadata(p) {
            Ok(m) if linked(&m) => return Err("storage_link_rejected"),
            Ok(_) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(io(e)),
        }
    }
    Ok(())
}
fn within(child: &Path, root: &Path) -> bool {
    #[cfg(windows)]
    {
        PathBuf::from(child.to_string_lossy().to_lowercase())
            .starts_with(PathBuf::from(root.to_string_lossy().to_lowercase()))
    }
    #[cfg(not(windows))]
    {
        child.starts_with(root)
    }
}
fn target(path: &str) -> Result<PathBuf> {
    let p = PathBuf::from(path);
    if !p.is_absolute()
        || p.parent().is_none()
        || p.components().any(|c| {
            matches!(
                c,
                std::path::Component::ParentDir | std::path::Component::CurDir
            )
        })
    {
        return Err("storage_invalid_path");
    }
    no_links(&p)?;
    Ok(p)
}
fn atomic_json(path: &Path, value: &Value) -> Result<()> {
    no_links(path)?;
    fs::create_dir_all(path.parent().ok_or("storage_invalid_path")?).map_err(io)?;
    let tmp = path.with_extension(format!(
        "pending-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .map_err(io)?;
        f.write_all(&serde_json::to_vec(value).map_err(|_| "storage_invalid_config")?)
            .map_err(io)?;
        f.sync_all().map_err(io)?;
        drop(f);
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            use windows_sys::Win32::Storage::FileSystem::{
                MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
            };
            let from: Vec<u16> = tmp.as_os_str().encode_wide().chain(Some(0)).collect();
            let to: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            if unsafe {
                MoveFileExW(
                    from.as_ptr(),
                    to.as_ptr(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                )
            } == 0
            {
                return Err("storage_pointer_write_failed");
            }
        }
        #[cfg(not(windows))]
        fs::rename(&tmp, path).map_err(io)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result
}
fn digest(path: &Path, cancel: &AtomicBool) -> Result<(u64, String)> {
    no_links(path)?;
    let mut file = File::open(path).map_err(io)?;
    let mut hash = Sha256::new();
    let mut size = 0;
    let mut buf = [0; 65536];
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err("storage_cancelled");
        }
        let n = file.read(&mut buf).map_err(io)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
        size += n as u64;
    }
    Ok((size, format!("{:x}", hash.finalize())))
}
fn files(root: &Path) -> Result<Vec<PathBuf>> {
    no_links(root)?;
    let mut out = Vec::new();
    if !root.exists() {
        return Ok(out);
    }
    let mut queue = vec![root.to_owned()];
    while let Some(dir) = queue.pop() {
        for entry in fs::read_dir(dir).map_err(io)? {
            let entry = entry.map_err(io)?;
            let p = entry.path();
            let m = fs::symlink_metadata(&p).map_err(io)?;
            if linked(&m) {
                return Err("storage_link_rejected");
            }
            if m.is_dir() {
                queue.push(p);
            } else if m.is_file() {
                out.push(p);
            }
        }
    }
    out.sort();
    Ok(out)
}
fn is_control(p: &Path) -> bool {
    matches!(
        p.file_name().and_then(|v| v.to_str()),
        Some(".storage-use.lock" | "workspace.lock")
    )
}
fn inventory(
    maps: &[(PathBuf, PathBuf)],
    cancel: &AtomicBool,
    pointer: &Path,
) -> Result<Vec<Entry>> {
    let mut result = Vec::new();
    for (source, target) in maps {
        for file in files(source)? {
            if is_control(&file)
                || file == pointer
                || file == source.join(".storage-migration.json")
            {
                continue;
            }
            let (bytes, hash) = digest(&file, cancel)?;
            result.push(Entry {
                target: target.join(
                    file.strip_prefix(source)
                        .map_err(|_| "storage_invalid_path")?,
                ),
                source: file,
                bytes,
                hash,
            });
        }
    }
    Ok(result)
}
fn progress(id: &str, phase: &str, done: u64, total: u64, error: Option<&str>) {
    if let Some(job) = JOB.get_or_init(Default::default).lock().unwrap().as_mut()
        && job.id == id
    {
        job.progress = json!({"job_id":id,"phase":phase,"done":done,"total":total,"error":error});
    }
}
fn enough_space(path: &Path, bytes: u64) -> Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut free = 0;
        if unsafe {
            windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(
                name.as_ptr(),
                &mut free,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err("storage_space_unknown");
        }
        if free < bytes.saturating_add(1024 * 1024) {
            return Err("storage_no_space");
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (path, bytes);
        return Err("storage_space_unknown");
    }
    #[allow(unreachable_code)]
    Ok(())
}
fn move_data(store: &Store, to: PathBuf, cancel: &AtomicBool, id: &str) -> Result<Pending> {
    if to.exists() && fs::read_dir(&to).map_err(io)?.next().is_some() {
        return Err("storage_target_not_empty");
    }
    let mut maps = vec![(store.data(), to.clone())];
    for kind in ["credentials", "book_sources"] {
        let from = store.path(kind);
        if !from.starts_with(store.data()) {
            maps.push((
                from,
                to.join(if kind == "credentials" {
                    "credentials-v1"
                } else {
                    "book-sources-v1"
                }),
            ));
        }
    }
    for (from, _) in &maps {
        if within(&to, from) || within(from, &to) {
            return Err("storage_overlapping_roots");
        }
    }
    if within(&to, &store.cache()) || within(&store.cache(), &to) {
        return Err("storage_overlapping_roots");
    }
    for kind in CACHE_KINDS {
        let cache = store.path(kind);
        if within(&to, &cache) || within(&cache, &to) {
            return Err("storage_overlapping_roots");
        }
    }
    fs::create_dir_all(&to).map_err(|_| "storage_target_not_writable")?;
    no_links(&to)?;
    let marker = to.join(".storage-write-test");
    let mut probe = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&marker)
        .map_err(|_| "storage_target_not_writable")?;
    probe
        .write_all(b"probe")
        .map_err(|_| "storage_target_not_writable")?;
    drop(probe);
    fs::remove_file(marker).map_err(io)?;
    progress(id, "scan", 0, 0, None);
    let entries = inventory(&maps, cancel, &store.pointer())?;
    let total = entries.iter().map(|e| e.bytes).sum();
    enough_space(&to, total)?;
    let mut done = 0;
    for e in &entries {
        if cancel.load(Ordering::Relaxed) {
            return Err("storage_cancelled");
        }
        fs::create_dir_all(e.target.parent().ok_or("storage_invalid_path")?).map_err(io)?;
        let mut src = File::open(&e.source).map_err(io)?;
        let mut dst = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&e.target)
            .map_err(io)?;
        let mut buf = [0; 65536];
        loop {
            if cancel.load(Ordering::Relaxed) {
                return Err("storage_cancelled");
            }
            let n = src.read(&mut buf).map_err(io)?;
            if n == 0 {
                break;
            }
            dst.write_all(&buf[..n]).map_err(io)?;
            done += n as u64;
            progress(id, "copy", done, total, None);
        }
        dst.sync_all().map_err(io)?;
        drop(dst);
        if digest(&e.target, cancel)? != (e.bytes, e.hash.clone()) {
            return Err("storage_verify_failed");
        }
    }
    progress(id, "verify", done, total, None);
    if inventory(&maps, cancel, &store.pointer())? != entries {
        return Err("storage_source_changed");
    }
    if cancel.load(Ordering::Relaxed) {
        return Err("storage_cancelled");
    }
    let manifest = to.join(".storage-migration.json");
    atomic_json(
        &manifest,
        &serde_json::to_value(Manifest {
            maps,
            files: entries,
        })
        .map_err(|_| "storage_invalid_config")?,
    )?;
    Ok(Pending {
        target: to,
        manifest,
    })
}
fn publish_move(pending: Pending) -> Result<()> {
    let mut guard = active().lock().unwrap();
    let current = guard.as_mut().ok_or("storage_not_initialized")?;
    let mut changed = current.clone();
    changed.config.pending = Some(pending);
    changed.save()?;
    *current = changed;
    Ok(())
}

fn initialize(mut store: Store) -> Result<Store> {
    if store.pointer().exists() {
        no_links(&store.pointer())?;
        store.config = serde_json::from_slice(&fs::read(store.pointer()).map_err(io)?)
            .map_err(|_| "storage_invalid_config")?;
    }
    if let Some(pending) = store.config.pending.take() {
        let cancel = AtomicBool::new(false);
        let manifest = fs::read(&pending.manifest)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Manifest>(&bytes).ok());
        let valid = manifest.as_ref().is_some_and(|m| {
            inventory(&m.maps, &cancel, &store.pointer()).is_ok_and(|v| v == m.files)
                && m.files.iter().all(|e| {
                    digest(&e.target, &cancel).is_ok_and(|v| v == (e.bytes, e.hash.clone()))
                })
        });
        if valid {
            store.config.data = Some(pending.target);
            store.config.aliases.extend(manifest.unwrap().maps);
        } else {
            store.startup_error = Some("storage_migration_stale".into());
        }
        store.save()?;
    }
    Ok(store)
}
pub fn remap_value(value: &mut Value) {
    let aliases = active()
        .lock()
        .unwrap()
        .as_ref()
        .map(|s| s.config.aliases.clone())
        .unwrap_or_default();
    fn visit(v: &mut Value, aliases: &[(PathBuf, PathBuf)]) {
        match v {
            Value::String(s) => {
                for (old, new) in aliases {
                    if let Ok(rel) = Path::new(s).strip_prefix(old) {
                        *s = new.join(rel).to_string_lossy().into_owned();
                    }
                }
            }
            Value::Array(a) => {
                for v in a {
                    visit(v, aliases)
                }
            }
            Value::Object(m) => {
                for v in m.values_mut() {
                    visit(v, aliases)
                }
            }
            _ => (),
        }
    }
    visit(value, &aliases);
}
/// 缓存目录共享租约。清理取得独占租约后才能删除；跨进程也生效。
pub fn retain_cache(kind: &str) -> std::result::Result<PathBuf, std::io::Error> {
    let root = path(kind);
    let key = root.to_string_lossy().into_owned();
    let mut leases = LEASES.get_or_init(Default::default).lock().unwrap();
    if let std::collections::btree_map::Entry::Vacant(entry) = leases.entry(key) {
        entry.insert(cache_file(&root)?);
    }
    Ok(root)
}
fn cache_file(root: &Path) -> std::result::Result<File, std::io::Error> {
    fs::create_dir_all(root)?;
    let f = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join(".storage-use.lock"))?;
    f.lock_shared()?;
    Ok(f)
}
fn asset(store: &Store, path: &Path) -> Result<Value> {
    no_links(path)?;
    let evidence =
        crate::assets::inspect(&path.to_string_lossy()).map_err(|_| "storage_invalid_image")?;
    let cancel = AtomicBool::new(false);
    let (bytes, hash) = digest(path, &cancel)?;
    if bytes != evidence.bytes || hash != evidence.sha256 {
        return Err("storage_source_changed");
    }
    let root = store.path("assets");
    no_links(&root)?;
    fs::create_dir_all(&root).map_err(io)?;
    let extension = &evidence.format;
    let destination = root.join(format!("{hash}.{extension}"));
    if !destination.exists() {
        let temp = root.join(format!(
            ".asset-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::copy(path, &temp).map_err(io)?;
        let result = (|| {
            if digest(&temp, &cancel)? != (bytes, hash.clone()) {
                return Err("storage_source_changed");
            }
            match fs::hard_link(&temp, &destination) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
                Err(e) => Err(io(e)),
            }
        })();
        let _ = fs::remove_file(temp);
        result?;
    }
    if digest(&destination, &cancel)? != (bytes, hash.clone()) {
        return Err("storage_verify_failed");
    }
    let _ = evidence;
    Ok(json!({"path":destination,"sha256":hash,"bytes":bytes}))
}
fn cache_stats(store: &Store) -> Result<Value> {
    let mut categories = Vec::new();
    let mut roots = Vec::new();
    for kind in CACHE_KINDS {
        roots.push((kind.to_string(), store.path(kind)));
    }
    for row in &store.config.old_caches {
        if !roots.contains(row) {
            roots.push(row.clone());
        }
    }
    for kind in CACHE_KINDS {
        let row = (
            kind.to_string(),
            Store {
                config: Config::default(),
                ..store.clone()
            }
            .path(kind),
        );
        if !roots.contains(&row) {
            roots.push(row);
        }
    }
    for (kind, root) in roots {
        let entries = files(&root)?;
        let bytes = entries
            .iter()
            .filter(|p| !is_control(p))
            .try_fold(0u64, |n, p| {
                fs::metadata(p).map(|m| n + m.len()).map_err(io)
            })?;
        categories.push(json!({"kind":kind,"path":root,"bytes":bytes,"files":entries.len()}));
    }
    let mut data = Vec::new();
    for kind in [
        "settings",
        "plugin_data",
        "plugins",
        "assets",
        "credentials",
        "book_sources",
    ] {
        let root = store.path(kind);
        let bytes = files(&root)?.iter().try_fold(0u64, |n, p| {
            fs::metadata(p).map(|m| n + m.len()).map_err(io)
        })?;
        data.push(json!({"kind":kind,"path":root,"bytes":bytes}));
    }
    Ok(json!({"cache":categories,"data":data,"old_cache_paths":store.config.old_caches}))
}
fn clean(store: &Store, kinds: &[Value]) -> Result<Value> {
    let mut rows = Vec::new();
    let mut roots = Vec::new();
    for kind in kinds {
        let kind = kind.as_str().ok_or("storage_invalid_category")?;
        if !CACHE_KINDS.contains(&kind) {
            return Err("storage_invalid_category");
        }
        roots.push((kind.to_string(), store.path(kind)));
        for (k, p) in &store.config.old_caches {
            if k == kind && !roots.contains(&(k.clone(), p.clone())) {
                roots.push((k.clone(), p.clone()));
            }
        }
        let legacy = Store {
            config: Config::default(),
            ..store.clone()
        }
        .path(kind);
        if !roots.contains(&(kind.into(), legacy.clone())) {
            roots.push((kind.into(), legacy));
        }
    }
    for (kind, root) in roots {
        let kind = kind.as_str();
        // 解包与历史生成封面可能被外部项目引用；先保留，不能猜测为无主缓存。
        if matches!(kind, "imports" | "generated_covers") {
            rows.push(json!({"kind":kind,"path":root,"deleted_bytes":0,"skipped":"persistent_reference_or_external_preview"}));
            continue;
        }
        // 真机预览是独立的浏览器资料目录（V107）：浏览器开着时一直占着 lockfile，删不掉就说明预览窗口还开着，整类跳过。
        if kind == "kindle_preview" {
            let lockfile = root.join("lockfile");
            if lockfile.exists() && fs::remove_file(&lockfile).is_err() {
                rows.push(
                    json!({"kind":kind,"path":root,"deleted_bytes":0,"skipped":"preview_open"}),
                );
                continue;
            }
        }
        if !root.exists() {
            rows.push(json!({"kind":kind,"path":root,"deleted_bytes":0,"deleted_files":0}));
            continue;
        }
        no_links(&root)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(root.join(".storage-use.lock"))
            .map_err(io)?;
        if lock.try_lock().is_err() {
            rows.push(json!({"kind":kind,"path":root,"deleted_bytes":0,"skipped":"in_use"}));
            continue;
        }
        let mut bytes = 0;
        let mut count = 0;
        let mut skipped = 0;
        let mut skipped_items = Vec::new();
        for file in files(&root)? {
            if is_control(&file) {
                continue;
            }
            let size = fs::metadata(&file).map_err(io)?.len();
            if fs::remove_file(&file).is_ok() {
                bytes += size;
                count += 1;
            } else {
                skipped += 1;
                skipped_items.push(json!({"path":file,"reason":"in_use_or_unwritable"}));
            }
        }
        rows.push(json!({"kind":kind,"path":root,"deleted_bytes":bytes,"deleted_files":count,"skipped_files":skipped,"skipped_items":skipped_items,"skip_reason":if skipped>0{Some("in_use_or_unwritable")}else{None}}));
    }
    Ok(json!({"categories":rows}))
}
pub fn request(text: String) -> String {
    let result = (|| -> Result<Value> {
        let req: Value = serde_json::from_str(&text).map_err(|_| "storage_invalid_request")?;
        let op = req["op"].as_str().ok_or("storage_invalid_request")?;
        let _control = if matches!(
            op,
            "initialize" | "move.start" | "cache.set" | "image.set" | "cache.clean" | "asset.copy"
        ) {
            Some(CONTROL.try_lock().map_err(|_| "storage_busy")?)
        } else {
            None
        };
        if op == "initialize" {
            let mut guard = active().lock().unwrap();
            if guard.is_none() {
                let mut s = Store::defaults();
                if let Some(p) = req["local"].as_str() {
                    s.local = target(p)?;
                }
                if let Some(p) = req["temp"].as_str() {
                    s.temp = target(p)?;
                }
                *guard = Some(initialize(s)?);
            }
            return Ok(guard.as_ref().unwrap().snapshot());
        }
        if matches!(op, "cache.set" | "image.set" | "cache.clean" | "asset.copy")
            && JOB
                .get_or_init(Default::default)
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|j| {
                    !matches!(
                        j.progress["phase"].as_str(),
                        Some("ready" | "failed" | "cancelled")
                    )
                })
        {
            return Err("storage_busy");
        }
        let store = active()
            .lock()
            .unwrap()
            .clone()
            .ok_or("storage_not_initialized")?;
        match op {
            "status" => Ok(store.snapshot()),
            "directory.stats" => {
                let root = target(req["path"].as_str().ok_or("storage_invalid_path")?)?;
                let list = files(&root)?;
                let bytes = list.iter().try_fold(0u64, |n, p| {
                    fs::metadata(p).map(|m| n + m.len()).map_err(io)
                })?;
                Ok(json!({"path":root,"bytes":bytes,"files":list.len()}))
            }
            "stats" => cache_stats(&store),
            "cache.clean" => clean(
                &store,
                req["kinds"].as_array().ok_or("storage_invalid_category")?,
            ),
            "asset.copy" => asset(
                &store,
                Path::new(req["path"].as_str().ok_or("storage_invalid_path")?),
            ),
            "lease.acquire" => {
                let kind = req["kind"].as_str().ok_or("storage_invalid_category")?;
                if !CACHE_KINDS.contains(&kind) {
                    return Err("storage_invalid_category");
                }
                let root = store.path(kind);
                let file = cache_file(&root).map_err(io)?;
                let id = NEXT.fetch_add(1, Ordering::Relaxed).to_string();
                LEASES
                    .get_or_init(Default::default)
                    .lock()
                    .unwrap()
                    .insert(id.clone(), file);
                Ok(json!({"lease":id,"path":root}))
            }
            "lease.release" => {
                let id = req["lease"].as_str().ok_or("storage_invalid_request")?;
                LEASES
                    .get_or_init(Default::default)
                    .lock()
                    .unwrap()
                    .remove(id);
                Ok(json!({}))
            }
            "cache.set" | "image.set" => {
                let mut guard = active().lock().unwrap();
                let current = guard.as_mut().unwrap();
                if current.config.pending.is_some() {
                    return Err("storage_restart_required");
                }
                let mut changed = current.clone();
                if op == "image.set" {
                    let mode = req["mode"]
                        .as_str()
                        .filter(|s| matches!(*s, "copy" | "reference"))
                        .ok_or("storage_invalid_mode")?;
                    changed.config.image_mode = Some(mode.into());
                } else {
                    let p = target(req["path"].as_str().ok_or("storage_invalid_path")?)?;
                    if within(&p, &current.data()) || within(&current.data(), &p) {
                        return Err("storage_overlapping_roots");
                    }
                    if p.exists()
                        && fs::read_dir(&p).map_err(io)?.next().is_some()
                        && !p.join(".easypub-cache.json").is_file()
                    {
                        return Err("storage_target_not_empty");
                    }
                    fs::create_dir_all(&p).map_err(|_| "storage_target_not_writable")?;
                    enough_space(&p, 0)?;
                    atomic_json(
                        &p.join(".easypub-cache.json"),
                        &json!({"owner":"EasyPub","schema":1}),
                    )
                    .map_err(|_| "storage_target_not_writable")?;
                    for kind in CACHE_KINDS {
                        let row = (kind.to_string(), current.path(kind));
                        if !changed.config.old_caches.contains(&row) {
                            changed.config.old_caches.push(row);
                        }
                    }
                    changed.config.cache = Some(p);
                }
                changed.save()?;
                *current = changed;
                Ok(current.snapshot())
            }
            "move.start" => {
                if req["plugins_stopped"] != true {
                    return Err("storage_plugins_running");
                }
                if store.config.pending.is_some() {
                    return Err("storage_restart_required");
                }
                let to = target(req["path"].as_str().ok_or("storage_invalid_path")?)?;
                let mut guard = JOB.get_or_init(Default::default).lock().unwrap();
                if guard.as_ref().is_some_and(|j| {
                    !matches!(
                        j.progress["phase"].as_str(),
                        Some("ready" | "failed" | "cancelled")
                    )
                }) {
                    return Err("storage_busy");
                }
                let id = NEXT.fetch_add(1, Ordering::Relaxed).to_string();
                let cancel = Arc::new(AtomicBool::new(false));
                *guard = Some(Job {
                    id: id.clone(),
                    cancel: cancel.clone(),
                    progress: json!({"job_id":id,"phase":"queued"}),
                });
                let job_id = id.clone();
                std::thread::spawn(move || {
                    let result = move_data(&store, to, &cancel, &job_id).and_then(publish_move);
                    match result {
                        Ok(()) => progress(&job_id, "ready", 0, 0, None),
                        Err(e) => progress(
                            &job_id,
                            if e == "storage_cancelled" {
                                "cancelled"
                            } else {
                                "failed"
                            },
                            0,
                            0,
                            Some(e),
                        ),
                    }
                });
                Ok(json!({"job_id":id}))
            }
            "move.poll" | "move.cancel" => {
                let guard = JOB.get_or_init(Default::default).lock().unwrap();
                let job = guard
                    .as_ref()
                    .filter(|j| Some(j.id.as_str()) == req["job_id"].as_str())
                    .ok_or("storage_job_missing")?;
                if op == "move.cancel" {
                    job.cancel.store(true, Ordering::Relaxed);
                }
                Ok(job.progress.clone())
            }
            _ => Err("storage_unknown_operation"),
        }
    })();
    match result {
        Ok(v) => json!({"ok":true,"result":v}).to_string(),
        Err(code) => json!({"ok":false,"error":code}).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        store: Store,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "easypub-v104-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&root).unwrap();
            Self {
                store: Store {
                    local: root.join("local"),
                    temp: root.join("temp"),
                    config: Config::default(),
                    startup_error: None,
                },
                root,
            }
        }
        fn seed(&self, kind: &str, name: &str, data: &[u8]) -> PathBuf {
            let p = self.store.path(kind).join(name);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(&p, data).unwrap();
            p
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            assert!(self.root.starts_with(std::env::temp_dir()));
            assert!(
                self.root
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("easypub-v104-")
            );
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn kindle_preview_is_cleaned_only_when_the_browser_is_closed() {
        let f = Fixture::new();
        let page = f.seed("kindle_preview", "Default/Cache/data_1", b"cached");
        let lock = f.seed("kindle_preview", "lockfile", b"");
        // 浏览器开着时占着 lockfile：用不带共享删除的方式打开来模拟，整类跳过。
        let held = {
            let mut o = OpenOptions::new();
            o.read(true).write(true);
            #[cfg(windows)]
            std::os::windows::fs::OpenOptionsExt::share_mode(&mut o, 0x1 | 0x2);
            o
        }
        .open(&lock)
        .unwrap();
        #[cfg(windows)]
        {
            let r = clean(&f.store, &[json!("kindle_preview")]).unwrap();
            assert_eq!(r["categories"][0]["skipped"], "preview_open");
            assert!(page.exists());
        }
        drop(held);
        let r = clean(&f.store, &[json!("kindle_preview")]).unwrap();
        assert!(r["categories"][0]["skipped"].is_null());
        assert!(!page.exists());
    }
    #[test]
    fn migration_activates_only_after_restart_and_verifies_separate_credentials() {
        let f = Fixture::new();
        assert!(!within(&f.store.cache(), &f.store.data()));
        let old = f.seed("settings", "workspace/source.txt", b"novel");
        f.seed("plugin_data", "example/location.json", b"legitimate-config");
        f.seed("credentials", "fake.dpapi", b"FAKE-SECRET");
        let pending = move_data(
            &f.store,
            f.root.join("destination"),
            &AtomicBool::new(false),
            "test",
        )
        .unwrap();
        assert!(old.exists());
        let mut stage = f.store.clone();
        stage.config.pending = Some(pending);
        stage.save().unwrap();
        assert_eq!(stage.data(), f.store.data());
        assert!(fs::metadata(stage.pointer()).unwrap().len() < 1024);
        let restarted = initialize(f.store.clone()).unwrap();
        assert_eq!(restarted.data(), f.root.join("destination"));
        assert_eq!(
            fs::read(restarted.path("credentials").join("fake.dpapi")).unwrap(),
            b"FAKE-SECRET"
        );
        assert_eq!(
            fs::read(restarted.path("plugin_data").join("example/location.json")).unwrap(),
            b"legitimate-config"
        );
        assert_eq!(restarted.config.aliases.len(), 3);
        assert!(old.exists());
    }
    #[test]
    fn stale_or_corrupt_copy_preserves_old_location() {
        for corrupt in [false, true] {
            let f = Fixture::new();
            let old = f.seed("settings", "value", b"before");
            let pending = move_data(
                &f.store,
                f.root.join("new"),
                &AtomicBool::new(false),
                "test",
            )
            .unwrap();
            fs::write(
                if corrupt {
                    f.root.join("new/settings/value")
                } else {
                    old
                },
                b"after",
            )
            .unwrap();
            let mut stage = f.store.clone();
            stage.config.pending = Some(pending);
            stage.save().unwrap();
            let loaded = initialize(f.store.clone()).unwrap();
            assert_eq!(loaded.data(), f.store.data());
            assert_eq!(
                loaded.startup_error.as_deref(),
                Some("storage_migration_stale")
            );
        }
    }
    #[test]
    fn cancel_overlap_and_nonempty_targets_do_not_publish() {
        let f = Fixture::new();
        f.seed("settings", "value", b"fake");
        assert!(matches!(
            move_data(&f.store, f.root.join("new"), &AtomicBool::new(true), "test"),
            Err("storage_cancelled")
        ));
        assert!(matches!(
            move_data(
                &f.store,
                f.store.data().join("nested"),
                &AtomicBool::new(false),
                "test"
            ),
            Err("storage_overlapping_roots")
        ));
        fs::create_dir_all(f.root.join("occupied")).unwrap();
        fs::write(f.root.join("occupied/user"), b"keep").unwrap();
        assert!(matches!(
            move_data(
                &f.store,
                f.root.join("occupied"),
                &AtomicBool::new(false),
                "test"
            ),
            Err("storage_target_not_empty")
        ));
        assert!(!f.store.pointer().exists());
    }
    #[test]
    fn cleanup_respects_locks_references_old_roots_and_unrelated_temp() {
        let f = Fixture::new();
        let preview = f.seed("content_preview", "old.xhtml", b"old");
        let cover = f.seed("generated_covers", "keep.png", b"image");
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(f.store.path("content_preview").join(".storage-use.lock"))
            .unwrap();
        lock.lock_shared().unwrap();
        assert_eq!(
            clean(&f.store, &[json!("content_preview")]).unwrap()["categories"][0]["skipped"],
            "in_use"
        );
        assert!(preview.exists());
        drop(lock);
        let mut store = f.store.clone();
        store.config.cache = Some(f.root.join("new-cache"));
        let unrelated = f.store.temp.join("user.txt");
        fs::write(&unrelated, b"keep").unwrap();
        clean(
            &store,
            &[json!("content_preview"), json!("generated_covers")],
        )
        .unwrap();
        assert!(!preview.exists());
        assert!(cover.exists());
        assert!(unrelated.exists());
    }
    #[test]
    fn images_deduplicate_by_content_and_keep_original() {
        let f = Fixture::new();
        let first = f.root.join("one.jpg");
        let second = f.root.join("two.jpeg");
        image::RgbImage::new(2, 2).save(&first).unwrap();
        fs::copy(&first, &second).unwrap();
        let a = asset(&f.store, &first).unwrap();
        let b = asset(&f.store, &second).unwrap();
        assert_eq!(a["path"], b["path"]);
        assert_eq!(files(&f.store.path("assets")).unwrap().len(), 1);
        assert!(first.exists());
    }
}
