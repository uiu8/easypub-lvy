//! 脚本只得到随机逻辑标识；读操作不接受或重新打开任何文件系统路径。
use ring::rand::{SecureRandom, SystemRandom};
use std::{
    collections::HashMap,
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
};

pub const MAX_FILE: usize = 16 * 1024 * 1024;
const MAX_TOTAL: usize = 64 * 1024 * 1024;
const MAX_COUNT: usize = 16;
#[derive(Default)]
pub struct Store {
    // Field order matters: close delete-on-close files, then unpin and remove root.
    files: HashMap<String, File>,
    #[cfg(windows)]
    pin: Option<File>,
    root: Option<tempfile::TempDir>,
    size: usize,
}
impl Store {
    pub fn capacity(&self) -> Result<usize, String> {
        if self.files.len() >= MAX_COUNT || self.size >= MAX_TOTAL {
            return Err("临时文件配额已用尽".into());
        }
        Ok(MAX_FILE.min(MAX_TOTAL - self.size))
    }
    fn init(&mut self) -> Result<(), String> {
        if self.root.is_some() {
            return Ok(());
        }
        let root = tempfile::Builder::new()
            .prefix("easypub-booksource-")
            .tempdir()
            .map_err(|_| "无法创建插件临时目录")?;
        #[cfg(windows)]
        {
            use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
            // BACKUP_SEMANTICS | OPEN_REPARSE_POINT; deny DELETE sharing so the
            // directory cannot be renamed/replaced while its file handles live.
            let pin = std::fs::OpenOptions::new()
                .read(true)
                .share_mode(3)
                .custom_flags(0x02000000 | 0x00200000)
                .open(root.path())
                .map_err(|_| "无法锁定插件临时目录")?;
            if pin
                .metadata()
                .map_err(|_| "无法检查插件临时目录")?
                .file_attributes()
                & 0x400
                != 0
            {
                return Err("插件临时目录不能是重解析点".into());
            }
            self.pin = Some(pin);
        }
        self.root = Some(root);
        Ok(())
    }
    pub fn put(&mut self, data: &[u8]) -> Result<String, String> {
        let context = crate::control::current();
        context.check()?;
        if data.len() > self.capacity()? {
            return Err("临时文件超过配额".into());
        }
        self.init()?;
        let mut random = [0; 16];
        SystemRandom::new()
            .fill(&mut random)
            .map_err(|_| "临时文件随机源失败")?;
        let id = format!("easypub-temp/{}.bin", hex::encode(random));
        let mut file = tempfile::tempfile_in(self.root.as_ref().unwrap().path())
            .map_err(|_| "无法创建临时文件")?;
        file.write_all(data).map_err(|_| "临时文件写入失败")?;
        context.check()?;
        self.size += data.len();
        self.files.insert(id.clone(), file);
        Ok(id)
    }
    pub fn read(&mut self, id: &str, charset: &str) -> Result<String, String> {
        crate::control::current().check()?;
        let encoding = match charset.to_ascii_uppercase().as_str() {
            "UTF-8" | "UTF8" => encoding_rs::UTF_8,
            "GBK" | "GB2312" => encoding_rs::GBK,
            "UTF-16LE" => encoding_rs::UTF_16LE,
            "UTF-16BE" => encoding_rs::UTF_16BE,
            _ => return Err("不支持的临时文本编码".into()),
        };
        let file = self.files.get_mut(id).ok_or("临时文件标识无效或已过期")?;
        file.seek(SeekFrom::Start(0))
            .map_err(|_| "临时文件读取失败")?;
        let mut data = Vec::new();
        file.take(MAX_FILE as u64 + 1)
            .read_to_end(&mut data)
            .map_err(|_| "临时文件读取失败")?;
        if data.len() > MAX_FILE {
            return Err("临时文件超过上限".into());
        }
        let (text, _, errors) = encoding.decode(&data);
        if errors
            || text
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
        {
            return Err("临时文件不是指定编码的文本".into());
        }
        crate::control::current().check()?;
        Ok(text.into_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn handles_isolate_paths_encoding_quota_and_cleanup() {
        let mut store = Store::default();
        let token = store.put("临时正文".as_bytes()).unwrap();
        let root = store.root.as_ref().unwrap().path().to_owned();
        assert_eq!(store.read(&token, "UTF-8").unwrap(), "临时正文");
        assert_eq!(store.read(&token, "UTF-8").unwrap(), "临时正文");
        for path in [
            "../outside.txt",
            "C:\\Windows\\win.ini",
            "file:///secret",
            "//host/share/a",
            "a:stream",
            "easypub-temp/../secret",
        ] {
            assert!(store.read(path, "UTF-8").is_err());
        }
        assert!(Store::default().read(&token, "UTF-8").is_err());
        let gbk = store.put(&encoding_rs::GBK.encode("合成文本").0).unwrap();
        assert_eq!(store.read(&gbk, "GBK").unwrap(), "合成文本");
        assert!(store.read(&gbk, "UTF-8").is_err());
        let binary = store.put(&[0, 1, 2]).unwrap();
        assert!(store.read(&binary, "UTF-8").is_err());
        #[cfg(windows)]
        assert!(std::fs::rename(&root, root.with_extension("renamed")).is_err());
        for _ in 3..MAX_COUNT {
            store.put(b"x").unwrap();
        }
        assert!(store.put(b"x").is_err());
        drop(store);
        assert!(!root.exists());
        let mut store = Store::default();
        let block = vec![b'x'; MAX_FILE];
        for _ in 0..4 {
            store.put(&block).unwrap();
        }
        assert!(store.put(b"x").is_err());
        let root = store.root.as_ref().unwrap().path().to_owned();
        let context = crate::control::Context::default();
        context
            .cancel
            .store(true, std::sync::atomic::Ordering::Relaxed);
        let _guard = context.enter();
        assert!(store.put(b"x").is_err());
        drop(store);
        assert!(!root.exists());
    }
}
