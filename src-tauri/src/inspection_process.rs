//! Imported binaries are data: only Apple's fixed inspection tools run on the host.
use std::{io::Read, process::{Command, Output, Stdio}, time::{Duration, Instant}};

pub(crate) fn bounded_output(command: &mut Command) -> std::io::Result<Output> {
    const LIMIT: u64 = 8 * 1024 * 1024;
    let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let read = |pipe: Box<dyn Read + Send>| std::thread::spawn(move || {
        let mut bytes = Vec::new();
        pipe.take(LIMIT + 1).read_to_end(&mut bytes).map(|_| bytes)
    });
    let out = read(Box::new(stdout));
    let err = read(Box::new(stderr));
    let deadline = Instant::now() + Duration::from_secs(15);
    let status = loop {
        if let Some(status) = child.try_wait()? { break status; }
        if Instant::now() >= deadline {
            let _ = child.kill(); let _ = child.wait();
            return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "Signing inspection exceeded its 15-second budget"));
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let stdout = out.join().map_err(|_| std::io::Error::other("Inspection reader failed"))??;
    let stderr = err.join().map_err(|_| std::io::Error::other("Inspection reader failed"))??;
    if stdout.len() as u64 > LIMIT || stderr.len() as u64 > LIMIT {
        return Err(std::io::Error::other("Signing inspection exceeded its 8 MiB output budget"));
    }
    Ok(Output { status, stdout, stderr })
}
