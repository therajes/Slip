//! Hermetic metadata-only protocol checks. No Apple, account, ADI provisioning,
//! Keychain, passwords or verification codes are involved.
use std::{
    io::{BufRead, BufReader, Write},
    net::TcpListener,
    sync::mpsc,
    thread,
    time::Duration,
};

use isideload::{
    anisette::{AnisetteProvider, remote_v3::RemoteV3AnisetteProvider},
    util::storage::InMemoryStorage,
};

fn fixture(
    status: &str,
    body: Vec<u8>,
) -> (String, thread::JoinHandle<()>, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let status = status.to_string();
    let (sender, receiver) = mpsc::channel();
    let server = thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "Fixture was not contacted"
                    );
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("Fixture failed: {error}"),
            }
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut first_line = String::new();
        reader.read_line(&mut first_line).unwrap();
        // Consume headers before replying, so closing the connection cannot
        // discard unread request bytes and turn the response into a reset.
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line == "\r\n" || line.is_empty() {
                break;
            }
        }
        let _ = sender.send(first_line);
        write!(stream, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).unwrap();
        let _ = stream.write_all(&body);
    });
    (format!("http://{address}/selected"), server, receiver)
}

fn provider(url: &str) -> RemoteV3AnisetteProvider {
    static CRYPTO: std::sync::Once = std::sync::Once::new();
    CRYPTO.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
    RemoteV3AnisetteProvider::new(url, Box::new(InMemoryStorage::new()), "fixture".into()).unwrap()
}

fn metadata(client_info: &str, user_agent: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({"client_info":client_info,"user_agent":user_agent}))
        .unwrap()
}

#[test]
fn selected_provider_metadata_is_preserved_and_cached_until_url_changes() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let (url, server, path) = fixture(
        "200 OK",
        metadata("<fixture-Mac> <macOS;27.0;fixture>", "fixture-UA/1"),
    );
    let selected = provider(&url);
    let info = runtime.block_on(selected.get_client_info()).unwrap();
    assert_eq!(info.client_info, "<fixture-Mac> <macOS;27.0;fixture>");
    assert_eq!(info.user_agent, "fixture-UA/1");
    assert!(
        path.recv_timeout(Duration::from_secs(2))
            .unwrap()
            .starts_with("GET /selected/v3/client_info ")
    );
    server.join().unwrap();
    // The fixture has closed. A second request must use the same identity rather
    // than contacting any public/default provider or fetching a new descriptor.
    assert_eq!(
        runtime
            .block_on(selected.get_client_info())
            .unwrap()
            .user_agent,
        "fixture-UA/1"
    );

    let (url, server, _) = fixture(
        "200 OK",
        metadata("<fixture-PC> <Windows;fixture>", "fixture-UA/2"),
    );
    let selected = selected.set_url(&url);
    let info = runtime.block_on(selected.get_client_info()).unwrap();
    assert_eq!(info.client_info, "<fixture-PC> <Windows;fixture>");
    assert_eq!(info.user_agent, "fixture-UA/2");
    server.join().unwrap();
}

#[test]
fn redirects_and_oversized_metadata_are_rejected_without_response_disclosure() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    for (status, bytes) in [
        ("302 Found", metadata("<fixture-redirect>", "fixture-UA")),
        (
            "200 OK",
            metadata(&"sensitive-fixture".repeat(700), "fixture-UA"),
        ),
    ] {
        let (url, server, _) = fixture(status, bytes);
        let result = runtime.block_on(provider(&url).get_client_info());
        assert!(result.is_err(), "Invalid service metadata must be rejected");
        assert!(
            !result
                .unwrap_err()
                .to_string()
                .contains("sensitive-fixture")
        );
        server.join().unwrap();
    }
}
