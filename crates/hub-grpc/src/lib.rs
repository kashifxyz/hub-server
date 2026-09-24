//! Hub's gRPC server (tonic).

use std::io;
use std::net::SocketAddr;

use tokio::sync::oneshot;
use tokio::task::{JoinError, JoinHandle};
use tonic::transport::server::TcpIncoming;

#[derive(Debug, thiserror::Error)]
pub enum GrpcError {
    #[error(transparent)]
    Transport(#[from] tonic::transport::Error),
    #[error("gRPC server task failed: {0}")]
    Task(#[from] JoinError),
}

/// Binds the gRPC port without serving yet, so a port that is already in use
/// fails before anything starts.
pub fn bind(addr: SocketAddr) -> io::Result<TcpIncoming> {
    TcpIncoming::bind(addr)
}

/// A running gRPC server.
pub struct GrpcServer {
    stop: oneshot::Sender<()>,
    task: JoinHandle<Result<(), tonic::transport::Error>>,
}

/// Starts serving on the already-bound listener.
pub fn start(incoming: TcpIncoming) -> GrpcServer {
    let (_health_reporter, health_service) = tonic_health::server::health_reporter();
    let (stop, stop_rx) = oneshot::channel::<()>();

    let task = tokio::spawn(
        tonic::transport::Server::builder()
            .add_service(health_service)
            .serve_with_incoming_shutdown(incoming, async {
                let _ = stop_rx.await;
            }),
    );

    GrpcServer { stop, task }
}

impl GrpcServer {
    /// Signals shutdown, lets in-flight calls finish, and waits for the
    /// server to exit.
    pub async fn stop(self) -> Result<(), GrpcError> {
        let _ = self.stop.send(());
        self.task.await??;
        Ok(())
    }
}
