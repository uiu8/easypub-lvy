//! 把文件移到 Windows 回收站：书库“彻底删除”与书源插件删除下载的书都用它。
//! 只处理已存在的普通文件、必须是绝对路径；不存在的跳过；不删除文件夹，不永久删除。
use easypub_core::{ApiError, ErrorCode};
use std::path::Path;

fn invalid(action: &'static str) -> ApiError {
    ApiError::new(ErrorCode::InvalidRule, "recycle", action)
}

/// 返回实际移到回收站的路径（不存在的不算）。
pub fn to_recycle_bin(paths: &[String]) -> Result<Vec<String>, ApiError> {
    if paths.len() > 1000 {
        return Err(invalid("delete_fewer_files"));
    }
    let mut targets = Vec::new();
    for path in paths {
        let p = Path::new(path);
        if !p.is_absolute() || path.contains('\0') {
            return Err(invalid("use_absolute_file_paths"));
        }
        match std::fs::symlink_metadata(p) {
            Ok(meta) if meta.is_file() => targets.push(path.clone()),
            Ok(_) => return Err(invalid("only_files_can_be_deleted")),
            Err(_) => {}
        }
    }
    if targets.is_empty() {
        return Ok(targets);
    }
    recycle(&targets)?;
    // 系统可能在用户取消或文件被占用时什么也不做：以文件是否还在为准。
    Ok(targets
        .into_iter()
        .filter(|p| !Path::new(p).exists())
        .collect())
}

#[cfg(windows)]
fn recycle(targets: &[String]) -> Result<(), ApiError> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::{
        FO_DELETE, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, SHFILEOPSTRUCTW,
        SHFileOperationW,
    };
    // 多个路径用 \0 分隔，整串以两个 \0 结尾。
    let mut from: Vec<u16> = Vec::new();
    for t in targets {
        from.extend(std::ffi::OsStr::new(t).encode_wide());
        from.push(0);
    }
    from.push(0);
    let mut op: SHFILEOPSTRUCTW = unsafe { std::mem::zeroed() };
    op.wFunc = FO_DELETE;
    op.pFrom = from.as_ptr();
    op.fFlags = (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT) as _;
    let code = unsafe { SHFileOperationW(&mut op) };
    if code != 0 {
        return Err(ApiError::new(
            ErrorCode::Io,
            "recycle",
            "close_programs_using_the_file",
        ));
    }
    Ok(())
}

#[cfg(not(windows))]
fn recycle(_targets: &[String]) -> Result<(), ApiError> {
    Err(invalid("recycle_bin_needs_windows"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "会往本机回收站放两个假数据文件；需要时用 --ignored 手动运行（V134 已通过）"]
    fn moves_files_to_recycle_bin_and_skips_missing_or_rejects_folders() {
        let dir = std::env::temp_dir().join(format!("ep-v134-recycle-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("甲.txt");
        let b = dir.join("乙.txt");
        std::fs::write(&a, "假数据").unwrap();
        std::fs::write(&b, "假数据").unwrap();
        let missing = dir.join("不存在.txt");
        let paths = [a.clone(), b.clone(), missing]
            .map(|p| p.to_string_lossy().into_owned())
            .to_vec();
        let done = to_recycle_bin(&paths).unwrap();
        assert_eq!(done.len(), 2);
        assert!(!a.exists() && !b.exists());
        assert!(to_recycle_bin(&[dir.to_string_lossy().into_owned()]).is_err());
        assert!(to_recycle_bin(&["相对路径.txt".into()]).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
