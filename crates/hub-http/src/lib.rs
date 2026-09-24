//! Hub's REST server (Actix Web).

use std::io;
use std::net::SocketAddr;

use actix_web::dev::{Server, ServerHandle};
use actix_web::{App, HttpServer};
use tokio::task::JoinHandle;

/// Binds the REST port without serving yet, so a port that is already in use
/// fails before anything starts.
pub fn bind(addr: SocketAddr) -> io::Result<Server> {
    let server = HttpServer::new(App::new)
        .bind(addr)?
        // The caller handles signals and stops the server through its handle.
        .disable_signals()
        .run();
    Ok(server)
}

/// A running REST server.
pub struct RestServer {
    handle: ServerHandle,
    task: JoinHandle<io::Result<()>>,
}

/// Starts serving on the already-bound server.
pub fn start(server: Server) -> RestServer {
    RestServer {
        handle: server.handle(),
        task: tokio::spawn(server),
    }
}

impl RestServer {
    /// Stops accepting connections, drains in-flight requests, and waits for
    /// the server to finish.
    pub async fn stop(self) -> io::Result<()> {
        self.handle.stop(true).await;
        self.task.await.map_err(io::Error::other)?
    }
}
