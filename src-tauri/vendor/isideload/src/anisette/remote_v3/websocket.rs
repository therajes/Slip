use futures::{SinkExt, StreamExt};
use rootcause::prelude::*;

pub enum WsMessage {
    Text(String),
    Close,
}

pub struct AppWebSocket {
    #[cfg(not(feature = "wasm"))]
    inner: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    #[cfg(feature = "wasm")]
    inner: ws_stream_wasm::WsStream,
    #[cfg(feature = "wasm")]
    meta: ws_stream_wasm::WsMeta,
}

impl AppWebSocket {
    pub async fn connect(url: &str, proxy_url: Option<&str>) -> Result<Self, Report> {
        let target_url = if proxy_url.is_some() {
            let proxied = format!("{}{}", proxy_url.unwrap(), urlencoding::encode(url))
                .replace("https://", "wss://");
            proxied
        } else {
            url.to_string()
        };

        #[cfg(not(feature = "wasm"))]
        {
            use tokio::time::{Duration, timeout};

            let (stream, _) = timeout(
                Duration::from_secs(30),
                tokio_tungstenite::connect_async(&target_url),
            )
            .await?
            .context(
                "Timed out connecting to provisioning socket. Try a different anisette server.",
            )?;
            Ok(Self { inner: stream })
        }
        #[cfg(feature = "wasm")]
        {
            let (meta, stream) = ws_stream_wasm::WsMeta::connect(&target_url, None)
                .await
                .map_err(|e| report!("WS connect failed: {e:?}"))?;
            Ok(Self {
                meta,
                inner: stream,
            })
        }
    }

    pub async fn send_text(&mut self, text: String) -> Result<(), Report> {
        #[cfg(not(feature = "wasm"))]
        self.inner
            .send(tokio_tungstenite::tungstenite::Message::Text(text.into()))
            .await?;
        #[cfg(feature = "wasm")]
        self.inner
            .send(ws_stream_wasm::WsMessage::Text(text))
            .await
            .map_err(|e| report!("WS send failed: {e:?}"))?;
        Ok(())
    }

    pub async fn next(&mut self) -> Option<Result<WsMessage, Report>> {
        #[cfg(not(feature = "wasm"))]
        {
            use tokio_tungstenite::tungstenite::Error;
            use tokio_tungstenite::tungstenite::error::ProtocolError;

            loop {
                let msg = self.inner.next().await?;
                match msg {
                    Ok(tokio_tungstenite::tungstenite::Message::Text(t)) => {
                        return Some(Ok(WsMessage::Text(t.to_string())));
                    }
                    Ok(tokio_tungstenite::tungstenite::Message::Close(_)) => {
                        return Some(Ok(WsMessage::Close));
                    }
                    Ok(tokio_tungstenite::tungstenite::Message::Ping(_)) => {
                        // Tungstenite queues the matching Pong while reading Ping.
                        if let Err(error) = self.inner.flush().await {
                            return Some(Err(error.into()));
                        }
                    }
                    Ok(
                        tokio_tungstenite::tungstenite::Message::Pong(_)
                        | tokio_tungstenite::tungstenite::Message::Frame(_),
                    ) => {}
                    Ok(tokio_tungstenite::tungstenite::Message::Binary(_)) => {
                        return Some(Err(report!(
                            "Unexpected binary payload from provisioning WebSocket"
                        )));
                    }
                    Err(
                        Error::ConnectionClosed
                        | Error::AlreadyClosed
                        | Error::Protocol(ProtocolError::ResetWithoutClosingHandshake),
                    ) => return Some(Ok(WsMessage::Close)),
                    Err(error) => return Some(Err(error.into())),
                }
            }
        }
        #[cfg(feature = "wasm")]
        {
            let msg = self.inner.next().await?;
            Some(Ok(match msg {
                ws_stream_wasm::WsMessage::Text(t) => WsMessage::Text(t),
                ws_stream_wasm::WsMessage::Binary(_) => WsMessage::Close,
            }))
        }
    }

    pub async fn close(&mut self) -> Result<(), Report> {
        #[cfg(not(feature = "wasm"))]
        {
            let _ = self.inner.close(None).await;
            Ok(())
        }
        #[cfg(feature = "wasm")]
        {
            let _ = self.meta.close().await;
            Ok(())
        }
    }
}

#[cfg(all(test, not(feature = "wasm")))]
mod tests {
    use super::*;
    #[test]
    fn heartbeat_frames_do_not_close_a_provisioning_connection() {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                use tokio_tungstenite::tungstenite::Message;
                let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
                let address = listener.local_addr().unwrap();
                let server = tokio::spawn(async move {
                    let (stream, _) = listener.accept().await.unwrap();
                    let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
                    socket
                        .send(Message::Ping(vec![1, 2, 3].into()))
                        .await
                        .unwrap();
                    socket.send(Message::Pong(vec![4].into())).await.unwrap();
                    socket
                        .send(Message::Text("fixture-message".into()))
                        .await
                        .unwrap();
                    let response = socket.next().await.unwrap().unwrap();
                    assert!(matches!(response, Message::Pong(_)));
                });
                let mut socket = AppWebSocket::connect(&format!("ws://{address}"), None)
                    .await
                    .unwrap();
                let message =
                    tokio::time::timeout(std::time::Duration::from_secs(2), socket.next())
                        .await
                        .unwrap()
                        .unwrap()
                        .unwrap();
                assert!(matches!(message, WsMessage::Text(text) if text == "fixture-message"));
                server.await.unwrap();
            });
    }
}
