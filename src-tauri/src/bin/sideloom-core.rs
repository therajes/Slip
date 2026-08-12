#[tokio::main]
async fn main() {
    std::panic::set_hook(Box::new(|panic| {
        if std::env::var_os("SIDELOOM_DIAGNOSTIC").is_some() {
            eprintln!("{panic}");
        }
        sideloom_lib::headless::emit_fatal(
            "Slip core encountered an unexpected internal error. Restart Slip and try again.",
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
        if std::env::var_os("SIDELOOM_DIAGNOSTIC").is_some() {
            eprintln!("{error:?}");
        }
        sideloom_lib::headless::emit_fatal(&sideloom_lib::headless::user_facing_error(
            error.as_ref(),
        ));
        std::process::exit(1);
    }
}
