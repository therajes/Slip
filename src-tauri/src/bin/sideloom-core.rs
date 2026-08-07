#[tokio::main]
async fn main() {
    std::panic::set_hook(Box::new(|panic| {
        sideloom_lib::headless::emit_fatal(&format!(
            "Slip core encountered an internal error: {panic}"
        ));
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
            &error.to_string(),
        ));
        std::process::exit(1);
    }
}
