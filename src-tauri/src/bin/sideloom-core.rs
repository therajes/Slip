#[tokio::main]
async fn main() {
    std::panic::set_hook(Box::new(|_| {
        // Panic payloads and dependency reports can contain private response data.
        sideloom_lib::headless::emit_fatal(
            "Slip’s signing engine encountered an internal error. Retry the operation.",
        );
    }));
    if rustls::crypto::ring::default_provider()
        .install_default()
        .is_err()
    {
        sideloom_lib::headless::emit_fatal("Unable to initialize the TLS crypto provider");
        std::process::exit(1);
    }
    if let Err(error) = sideloom_lib::headless::run().await {
        let message = error.human_message();
        let final_message = if message.trim().is_empty() || message.to_lowercase() == "misc" {
            sideloom_lib::headless::user_facing_error(&error.to_string())
        } else {
            message
        };
        if let Ok(home) = std::env::var("HOME") {
            let log_dir = std::path::PathBuf::from(home).join("Library/Logs/Slip");
            let _ = std::fs::create_dir_all(&log_dir);
            let log_path = log_dir.join("core.log");
            let mut options = std::fs::OpenOptions::new();
            options.create(true).append(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            if let Ok(mut file) = options.open(log_path) {
                use std::io::Write;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = file.set_permissions(std::fs::Permissions::from_mode(0o600));
                }
                let error_kind: &str = error.as_ref();
                let _ = writeln!(
                    file,
                    "[{}] operation failed ({})",
                    chrono::Local::now(),
                    error_kind
                );
            }
        }
        sideloom_lib::headless::emit_fatal(&final_message);
        std::process::exit(1);
    }

}
