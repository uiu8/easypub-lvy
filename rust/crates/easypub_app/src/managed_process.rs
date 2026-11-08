//! Blocking Windows worker. Child trees remain owned even during cancellation/panic.
use std::{
    ffi::OsStr,
    fs::File,
    io, mem,
    os::windows::{ffi::OsStrExt, io::AsRawHandle},
    path::Path,
    ptr,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::*,
    System::{JobObjects::*, Threading::*},
};

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Exited(u32),
    Cancelled,
    TimedOut,
    LogLimit,
}
struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
fn checked(ok: i32) -> io::Result<()> {
    if ok == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
fn wide(value: &OsStr) -> io::Result<Vec<u16>> {
    let mut value: Vec<_> = value.encode_wide().collect();
    if value.contains(&0) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "embedded NUL"));
    }
    value.push(0);
    Ok(value)
}
// Microsoft CRT argv quoting, without invoking a shell.
fn quoted(value: &OsStr, out: &mut Vec<u16>) -> io::Result<()> {
    let value = wide(value)?;
    out.push(34);
    let mut slashes = 0;
    for &c in &value[..value.len() - 1] {
        if c == 92 {
            slashes += 1;
            continue;
        }
        out.extend(std::iter::repeat_n(
            92,
            if c == 34 { slashes * 2 + 1 } else { slashes },
        ));
        out.push(c);
        slashes = 0;
    }
    out.extend(std::iter::repeat_n(92, slashes * 2));
    out.push(34);
    Ok(())
}
struct Attributes {
    storage: Vec<usize>,
}
impl Attributes {
    fn pointer(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.storage.as_mut_ptr().cast()
    }
    fn new(handles: &mut [HANDLE]) -> io::Result<Self> {
        unsafe {
            let mut bytes = 0;
            InitializeProcThreadAttributeList(ptr::null_mut(), 1, 0, &mut bytes);
            let mut storage = vec![0usize; bytes.div_ceil(mem::size_of::<usize>())];
            // Do not call DeleteProcThreadAttributeList on failed initialization.
            checked(InitializeProcThreadAttributeList(
                storage.as_mut_ptr().cast(),
                1,
                0,
                &mut bytes,
            ))?;
            let mut this = Self { storage };
            checked(UpdateProcThreadAttribute(
                this.pointer(),
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles.as_mut_ptr().cast(),
                mem::size_of_val(handles),
                ptr::null_mut(),
                ptr::null(),
            ))?;
            Ok(this)
        }
    }
}
impl Drop for Attributes {
    fn drop(&mut self) {
        unsafe {
            DeleteProcThreadAttributeList(self.pointer());
        }
    }
}

/// `log_path` must be new; artifacts remain available after failure. Cancellation is
/// checked before launch and while running. No process is allowed to run before
/// assignment to the kill-on-close job. Call on a blocking worker, never the UI.
pub fn run(
    executable: &Path,
    arguments: &[&OsStr],
    directory: &Path,
    log_path: &Path,
    timeout: Duration,
    cancelled: impl Fn() -> bool,
) -> io::Result<Outcome> {
    if cancelled() {
        return Ok(Outcome::Cancelled);
    }
    let executable = executable.canonicalize()?;
    let app = wide(executable.as_os_str())?;
    let directory = wide(directory.canonicalize()?.as_os_str())?;
    let mut command = Vec::new();
    quoted(executable.as_os_str(), &mut command)?;
    for arg in arguments {
        command.push(32);
        quoted(arg, &mut command)?;
    }
    command.push(0);
    if command.len() > 32767 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "command too long",
        ));
    }
    let log = File::create_new(log_path)?;
    let input = File::open("NUL")?;
    unsafe {
        checked(SetHandleInformation(
            log.as_raw_handle(),
            HANDLE_FLAG_INHERIT,
            HANDLE_FLAG_INHERIT,
        ))?;
        checked(SetHandleInformation(
            input.as_raw_handle(),
            HANDLE_FLAG_INHERIT,
            HANDLE_FLAG_INHERIT,
        ))?;
        let mut handles = [log.as_raw_handle(), input.as_raw_handle()];
        let mut attributes = Attributes::new(&mut handles)?;
        let raw_job = CreateJobObjectW(ptr::null(), ptr::null());
        if raw_job.is_null() {
            return Err(io::Error::last_os_error());
        }
        let job = Handle(raw_job);
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = mem::zeroed();
        limits.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
        limits.BasicLimitInformation.ActiveProcessLimit = 64;
        checked(SetInformationJobObject(
            job.0,
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            mem::size_of_val(&limits) as u32,
        ))?;
        let mut startup: STARTUPINFOEXW = mem::zeroed();
        startup.StartupInfo.cb = mem::size_of_val(&startup) as u32;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = input.as_raw_handle();
        startup.StartupInfo.hStdOutput = log.as_raw_handle();
        startup.StartupInfo.hStdError = log.as_raw_handle();
        startup.lpAttributeList = attributes.pointer();
        let mut info: PROCESS_INFORMATION = mem::zeroed();
        checked(CreateProcessW(
            app.as_ptr(),
            command.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            1,
            CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
            ptr::null(),
            directory.as_ptr(),
            &startup.StartupInfo,
            &mut info,
        ))?;
        let process = Handle(info.hProcess);
        let thread = Handle(info.hThread);
        if AssignProcessToJobObject(job.0, process.0) == 0 {
            let error = io::Error::last_os_error();
            TerminateProcess(process.0, 1);
            WaitForSingleObject(process.0, 5000);
            return Err(error);
        }
        if ResumeThread(thread.0) == u32::MAX {
            return Err(io::Error::last_os_error());
        }
        let start = Instant::now();
        let outcome = loop {
            if cancelled() {
                break Outcome::Cancelled;
            }
            if start.elapsed() >= timeout {
                break Outcome::TimedOut;
            }
            if log.metadata()?.len() > 16 * 1024 * 1024 {
                break Outcome::LogLimit;
            }
            match WaitForSingleObject(process.0, 25) {
                WAIT_OBJECT_0 => {
                    let mut code = 0;
                    checked(GetExitCodeProcess(process.0, &mut code))?;
                    break Outcome::Exited(code);
                }
                WAIT_TIMEOUT => (),
                _ => return Err(io::Error::last_os_error()),
            }
        };
        // Also terminate any descendants left after a nominally successful parent.
        // Accounting reaches zero slightly before process handles are signalled.
        // Retain handles to the live tree before termination and wait for both.
        #[repr(C)]
        struct ProcessIds {
            assigned: u32,
            count: u32,
            ids: [usize; 64],
        }
        let mut ids: ProcessIds = mem::zeroed();
        checked(QueryInformationJobObject(
            job.0,
            JobObjectBasicProcessIdList,
            (&mut ids as *mut ProcessIds).cast(),
            mem::size_of_val(&ids) as u32,
            ptr::null_mut(),
        ))?;
        let mut descendants = Vec::new();
        for pid in &ids.ids[..ids.count as usize] {
            let handle = OpenProcess(PROCESS_SYNCHRONIZE, 0, *pid as u32);
            if !handle.is_null() {
                descendants.push(Handle(handle));
            } else if GetLastError() != ERROR_INVALID_PARAMETER {
                return Err(io::Error::last_os_error());
            }
        }
        checked(TerminateJobObject(job.0, 1))?;
        let deadline = Instant::now() + Duration::from_secs(5);
        for descendant in &descendants {
            let remaining = deadline
                .saturating_duration_since(Instant::now())
                .as_millis() as u32;
            if WaitForSingleObject(descendant.0, remaining) != WAIT_OBJECT_0 {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "descendant still terminating",
                ));
            }
        }
        loop {
            let mut accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = mem::zeroed();
            checked(QueryInformationJobObject(
                job.0,
                JobObjectBasicAccountingInformation,
                (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),
                mem::size_of_val(&accounting) as u32,
                ptr::null_mut(),
            ))?;
            if accounting.ActiveProcesses == 0 {
                break;
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "process tree still terminating",
                ));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        log.sync_all()?;
        Ok(outcome)
    }
}
