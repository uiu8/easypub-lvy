//! Publish a closed, same-volume staging file without replacing existing data.
use std::{io, path::Path};

/// Own only directories freshly created for a save, until its project is published.
#[derive(Default)]
pub(crate) struct StagedDirectories(Vec<std::path::PathBuf>);

impl StagedDirectories {
    pub(crate) fn create(&mut self, path: &Path) -> io::Result<()> {
        std::fs::create_dir(path)?;
        self.0.push(path.to_path_buf());
        Ok(())
    }

    pub(crate) fn keep(mut self) {
        self.0.clear();
    }
}

impl Drop for StagedDirectories {
    fn drop(&mut self) {
        for directory in self.0.iter().rev() {
            let _ = std::fs::remove_dir_all(directory);
        }
    }
}

#[cfg(windows)]
pub(crate) fn move_new(staged: &Path, target: &Path) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{MOVEFILE_WRITE_THROUGH, MoveFileExW};
    let wide = |path: &Path| -> io::Result<Vec<u16>> {
        let mut value: Vec<u16> = path.as_os_str().encode_wide().collect();
        if value.contains(&0) {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        value.push(0);
        Ok(value)
    };
    let from = wide(staged)?;
    let to = wide(target)?;
    // No REPLACE_EXISTING or COPY_ALLOWED: publication stays on the same volume,
    // fails if another writer won, and also works on FAT/exFAT without hard links.
    if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(windows))]
pub(crate) fn move_new(staged: &Path, target: &Path) -> io::Result<()> {
    std::fs::hard_link(staged, target)?;
    std::fs::remove_file(staged)
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    #[test]
    fn repair88_publish_has_one_winner_and_preserves_losing_stages() {
        let root = std::env::temp_dir().join(format!(
            "easypub-publish-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let target = root.join("published.bin");
        let barrier = Arc::new(Barrier::new(8));
        let workers = (0..8)
            .map(|id| {
                let stage = root.join(format!("stage-{id}"));
                std::fs::write(&stage, vec![id; 1024]).unwrap();
                let barrier = barrier.clone();
                let target = target.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    (id, stage.clone(), move_new(&stage, &target).is_ok())
                })
            })
            .collect::<Vec<_>>();
        let results = workers
            .into_iter()
            .map(|w| w.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|r| r.2).count(), 1);
        for (id, stage, won) in results {
            if won {
                assert!(!stage.exists());
                assert_eq!(std::fs::read(&target).unwrap(), vec![id; 1024]);
            } else {
                assert_eq!(std::fs::read(&stage).unwrap(), vec![id; 1024]);
            }
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
