//! A long-lived HTTP GET whose socket we own, for the legacy SSE transport.
//!
//! ureq hands back a body reader and never the socket under it, so a thread
//! blocked reading an event stream could only be woken by the *server* hanging
//! up. Every reconnect leaked the old stream and its reader thread. Here the
//! connection keeps a clone of the `TcpStream`; shutting that down makes the
//! blocked read return, and the reader thread ends.
//!
//! Deliberately small: one GET, HTTP/1.1, identity or chunked bodies, TLS
//! through the same rustls ureq is built on. Everything else still goes
//! through ureq.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use super::auth::resource_metadata_from;
use super::conn::ConnError;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_HEADER_BYTES: usize = 64 * 1024;

/// Shuts the socket down when dropped (or on [`close`](Self::close)).
pub struct Shutter(TcpStream);

impl Shutter {
    pub fn close(&self) {
        let _ = self.0.shutdown(Shutdown::Both);
    }
}

impl Drop for Shutter {
    fn drop(&mut self) {
        self.close();
    }
}

/// An open event stream: the body, and the handle that ends it.
pub struct EventStream {
    pub body: Box<dyn Read + Send>,
    pub shutter: Shutter,
}

trait Stream: Read + Write + Send {}
impl<T: Read + Write + Send> Stream for T {}

fn tls_config() -> Arc<rustls::ClientConfig> {
    use std::sync::OnceLock;
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let roots = rustls::RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
            };
            let provider = Arc::new(rustls::crypto::ring::default_provider());
            Arc::new(
                rustls::ClientConfig::builder_with_provider(provider)
                    .with_safe_default_protocol_versions()
                    .expect("ring supports the default protocol versions")
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            )
        })
        .clone()
}

fn closed(url: &str, what: impl std::fmt::Display) -> ConnError {
    ConnError::Closed(format!("{url}: {what}"))
}

/// `GET url` with `Accept: text/event-stream`. A 401 is an auth error, carrying
/// the resource metadata URL if the challenge names one.
pub fn open(url: &str, headers: &[(String, String)]) -> Result<EventStream, ConnError> {
    let u = url::Url::parse(url).map_err(|e| closed(url, e))?;
    let host = u
        .host_str()
        .ok_or_else(|| closed(url, "no host"))?
        .to_string();
    let port = u
        .port_or_known_default()
        .ok_or_else(|| closed(url, "no port"))?;
    let https = match u.scheme() {
        "https" => true,
        "http" => false,
        other => return Err(closed(url, format!("unsupported scheme {other}"))),
    };
    for (k, v) in headers {
        if k.contains(['\r', '\n', ':']) || v.contains(['\r', '\n']) {
            return Err(closed(url, format!("header {k:?} contains a line break")));
        }
    }

    let addrs: Vec<_> = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| closed(url, e))?
        .collect();
    let mut last = io::Error::new(io::ErrorKind::NotFound, "no addresses");
    let tcp = addrs
        .iter()
        .find_map(|a| match TcpStream::connect_timeout(a, CONNECT_TIMEOUT) {
            Ok(s) => Some(s),
            Err(e) => {
                last = e;
                None
            }
        })
        .ok_or_else(|| closed(url, last))?;
    let _ = tcp.set_nodelay(true);
    let _ = tcp.set_write_timeout(Some(CONNECT_TIMEOUT));
    // Bounded while the response head arrives; unbounded for the stream itself.
    let _ = tcp.set_read_timeout(Some(CONNECT_TIMEOUT));
    let shutter = Shutter(tcp.try_clone().map_err(|e| closed(url, e))?);
    let reset = tcp.try_clone().map_err(|e| closed(url, e))?;

    let mut stream: Box<dyn Stream> = if https {
        let name =
            rustls::pki_types::ServerName::try_from(host.clone()).map_err(|e| closed(url, e))?;
        let conn = rustls::ClientConnection::new(tls_config(), name).map_err(|e| closed(url, e))?;
        Box::new(rustls::StreamOwned::new(conn, tcp))
    } else {
        Box::new(tcp)
    };

    let mut target = u.path().to_string();
    if let Some(q) = u.query() {
        target.push('?');
        target.push_str(q);
    }
    let host_header = match u.port() {
        Some(p) => format!("{host}:{p}"),
        None => host.clone(),
    };
    let mut request = format!(
        "GET {target} HTTP/1.1\r\nHost: {host_header}\r\nAccept: text/event-stream\r\n\
         Cache-Control: no-cache\r\nUser-Agent: nautilus-mcp/{}\r\n",
        env!("CARGO_PKG_VERSION")
    );
    for (k, v) in headers {
        request.push_str(&format!("{k}: {v}\r\n"));
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .and_then(|_| stream.flush())
        .map_err(|e| closed(url, e))?;

    let mut reader = BufReader::new(stream);
    let (status, head) = read_head(&mut reader).map_err(|e| closed(url, e))?;
    let header = |name: &str| {
        head.iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    };
    if status == 401 {
        return Err(ConnError::Auth {
            message: format!("{url} answered 401 Unauthorized"),
            resource_metadata: header("WWW-Authenticate").and_then(resource_metadata_from),
        });
    }
    if !(200..300).contains(&status) {
        return Err(closed(url, format!("HTTP {status}")));
    }
    let _ = reset.set_read_timeout(None);

    let chunked =
        header("Transfer-Encoding").is_some_and(|v| v.to_ascii_lowercase().contains("chunked"));
    let length = header("Content-Length").and_then(|v| v.trim().parse::<u64>().ok());
    let body: Box<dyn Read + Send> = match (chunked, length) {
        (true, _) => Box::new(Chunked::new(reader)),
        (false, Some(n)) => Box::new(reader.take(n)),
        (false, None) => Box::new(reader),
    };
    Ok(EventStream { body, shutter })
}

/// The status code and headers.
fn read_head(r: &mut impl BufRead) -> io::Result<(u16, Vec<(String, String)>)> {
    let mut total = 0;
    let mut line = String::new();
    let mut next = |line: &mut String| -> io::Result<()> {
        line.clear();
        let n = r.read_line(line)?;
        total += n;
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "connection closed",
            ));
        }
        if total > MAX_HEADER_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "response head too large",
            ));
        }
        Ok(())
    };
    next(&mut line)?;
    let status = line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("bad status line {line:?}"),
            )
        })?;
    let mut headers = Vec::new();
    loop {
        next(&mut line)?;
        let l = line.trim_end_matches(['\r', '\n']);
        if l.is_empty() {
            return Ok((status, headers));
        }
        if let Some((k, v)) = l.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
}

/// `Transfer-Encoding: chunked`.
struct Chunked<R> {
    inner: R,
    remaining: u64,
    done: bool,
}

impl<R: BufRead> Chunked<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            remaining: 0,
            done: false,
        }
    }
}

impl<R: BufRead> Read for Chunked<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.done || buf.is_empty() {
            return Ok(0);
        }
        if self.remaining == 0 {
            let mut line = String::new();
            if self.inner.read_line(&mut line)? == 0 {
                self.done = true;
                return Ok(0);
            }
            let size = line.trim().split(';').next().unwrap_or("").trim();
            self.remaining = u64::from_str_radix(size, 16).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("bad chunk size {size:?}"),
                )
            })?;
            if self.remaining == 0 {
                self.done = true;
                return Ok(0);
            }
        }
        let want = buf.len().min(self.remaining as usize);
        let n = self.inner.read(&mut buf[..want])?;
        if n == 0 {
            self.done = true;
            return Ok(0);
        }
        self.remaining -= n as u64;
        if self.remaining == 0 {
            let mut crlf = String::new();
            self.inner.read_line(&mut crlf)?;
        }
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::time::Instant;

    #[test]
    fn chunked_bodies_decode() {
        let wire = "5\r\nhello\r\n7;ext=1\r\n, world\r\n0\r\n\r\n";
        let mut out = String::new();
        Chunked::new(wire.as_bytes())
            .read_to_string(&mut out)
            .unwrap();
        assert_eq!(out, "hello, world");
        assert!(Chunked::new("zz\r\n".as_bytes())
            .read_to_string(&mut String::new())
            .is_err());
    }

    /// A server that answers the GET, sends one event, and then holds the
    /// connection open forever — as a quiet SSE server does.
    fn quiet_server(
        status: &'static str,
        extra: &'static str,
    ) -> (String, std::sync::mpsc::Receiver<Instant>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut head = Vec::new();
            let mut b = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") && s.read(&mut b).unwrap_or(0) == 1 {
                head.push(b[0]);
            }
            let _ = write!(
                s,
                "HTTP/1.1 {status}\r\nContent-Type: text/event-stream\r\n{extra}Transfer-Encoding: chunked\r\n\r\n"
            );
            let event = "event: endpoint\ndata: /messages?s=1\n\n";
            let _ = write!(s, "{:x}\r\n{event}\r\n", event.len());
            let _ = s.flush();
            // Block until the client hangs up, then say when.
            let mut sink = [0u8; 64];
            while s.read(&mut sink).unwrap_or(0) > 0 {}
            let _ = tx.send(Instant::now());
        });
        (format!("http://{addr}/sse"), rx)
    }

    #[test]
    fn closing_ends_a_quiet_stream_and_its_reader() {
        let (url, hung_up) = quiet_server("200 OK", "");
        let es = open(&url, &[("X-Test".into(), "1".into())]).unwrap();
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let mut body = es.body;
        let reader = std::thread::spawn(move || {
            let mut first = vec![0u8; 64];
            let n = body.read(&mut first).unwrap();
            assert!(String::from_utf8_lossy(&first[..n]).contains("endpoint"));
            // Now blocked: the server sends nothing more, ever.
            let mut rest = Vec::new();
            let _ = body.read_to_end(&mut rest);
            let _ = done_tx.send(());
        });
        std::thread::sleep(Duration::from_millis(200));
        assert!(
            done_rx.try_recv().is_err(),
            "the reader should still be waiting"
        );

        let closed_at = Instant::now();
        es.shutter.close();
        done_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("closing must wake the blocked reader");
        reader.join().unwrap();
        let server_saw = hung_up
            .recv_timeout(Duration::from_secs(2))
            .expect("the server must see the hang-up");
        assert!(server_saw >= closed_at);
    }

    #[test]
    fn a_401_carries_the_resource_metadata() {
        let (url, _) = quiet_server(
            "401 Unauthorized",
            "WWW-Authenticate: Bearer resource_metadata=\"http://a/.well-known/oauth-protected-resource\"\r\n",
        );
        match open(&url, &[]) {
            Err(ConnError::Auth {
                resource_metadata, ..
            }) => assert_eq!(
                resource_metadata.as_deref(),
                Some("http://a/.well-known/oauth-protected-resource")
            ),
            Err(other) => panic!("expected an auth error, got {other}"),
            Ok(_) => panic!("expected an auth error, got a stream"),
        }
    }

    /// Needs the network, so not in the default run:
    /// `cargo test -- --ignored tls`.
    #[test]
    #[ignore]
    fn tls_handshake_against_a_public_host() {
        let es = open("https://example.com/", &[]).expect("TLS to a public host");
        let mut body = String::new();
        es.body.take(4096).read_to_string(&mut body).unwrap();
        assert!(body.to_lowercase().contains("<html"), "{body}");
    }

    #[test]
    fn header_injection_is_refused() {
        let r = open(
            "http://127.0.0.1:9/x",
            &[("X".into(), "a\r\nEvil: 1".into())],
        );
        assert!(matches!(r, Err(ConnError::Closed(m)) if m.contains("line break")));
    }
}
