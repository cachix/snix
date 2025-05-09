use std::{future::Future, ops::DerefMut, sync::Arc};

use bytes::Bytes;
use tokio::{
    io::{split, AsyncReadExt, AsyncWriteExt, ReadHalf, WriteHalf},
    sync::Mutex,
};
use tracing::{debug, warn};

use super::{
    framing::{NixFramedReader, StderrReadFramedReader},
    types::{AddToStoreNarRequest, QueryValidPaths},
    worker_protocol::{server_handshake_client, ClientSettings, Operation, Trust, STDERR_LAST},
    NixDaemonIO,
};

use crate::{
    store_path::StorePath,
    wire::{
        de::{NixRead, NixReader},
        ser::{NixSerialize, NixWrite, NixWriter, NixWriterBuilder},
        ProtocolVersion,
    },
};

use crate::{nix_daemon::types::NixError, worker_protocol::STDERR_ERROR};

/// Handles a single connection with a nix client.
///
/// As part of its [`initialization`] it performs the handshake with the client
/// and determines the [ProtocolVersion] and [ClientSettings] to use for the remainder of the session.
///
/// Once initialized, [NixDaemon::handle_client] needs to be called to handle
/// the rest of the session, it delegates all operation handling to an instance
/// of [NixDaemonIO].
///
/// [`initialization`]: NixDaemon::initialize
#[allow(dead_code)]
pub struct NixDaemon<IO, R, W> {
    io: Arc<IO>,
    protocol_version: ProtocolVersion,
    client_settings: ClientSettings,
    reader: NixReader<R>,
    writer: Arc<Mutex<NixWriter<W>>>,
}

impl<IO, R, W> NixDaemon<IO, R, W>
where
    IO: NixDaemonIO + Sync + Send,
{
    pub fn new(
        io: Arc<IO>,
        protocol_version: ProtocolVersion,
        client_settings: ClientSettings,
        reader: NixReader<R>,
        writer: NixWriter<W>,
    ) -> Self {
        Self {
            io,
            protocol_version,
            client_settings,
            reader,
            writer: Arc::new(Mutex::new(writer)),
        }
    }
}

impl<IO, RW> NixDaemon<IO, ReadHalf<RW>, WriteHalf<RW>>
where
    RW: AsyncReadExt + AsyncWriteExt + Send + Unpin + 'static,
    IO: NixDaemonIO + Sync + Send,
{
    /// Async constructor for NixDaemon.
    ///
    /// Performs the initial handshake with the client and retrieves the client's preferred
    /// settings.
    ///
    /// The resulting daemon can handle the client session by calling [NixDaemon::handle_client].
    pub async fn initialize(io: Arc<IO>, mut connection: RW) -> Result<Self, std::io::Error>
    where
        RW: AsyncReadExt + AsyncWriteExt + Send + Unpin,
    {
        let protocol_version =
            server_handshake_client(&mut connection, "2.18.2", Trust::Trusted).await?;

        connection.write_u64_le(STDERR_LAST).await?;
        let (reader, writer) = split(connection);
        let mut reader = NixReader::builder()
            .set_version(protocol_version)
            .build(reader);
        let mut writer = NixWriterBuilder::default()
            .set_version(protocol_version)
            .build(writer);

        // The first op is always SetOptions
        let operation: Operation = reader.read_value().await?;
        if operation != Operation::SetOptions {
            return Err(std::io::Error::other(
                "Expected SetOptions operation, but got {operation}",
            ));
        }
        let client_settings: ClientSettings = reader.read_value().await?;
        writer.write_number(STDERR_LAST).await?;
        writer.flush().await?;

        Ok(Self::new(
            io,
            protocol_version,
            client_settings,
            reader,
            writer,
        ))
    }

    /// Main client connection loop, reads client's requests and responds to them accordingly.
    pub async fn handle_client(&mut self) -> Result<(), std::io::Error> {
        let io = self.io.clone();
        loop {
            let op_code = self.reader.read_number().await?;
            let op = TryInto::<Operation>::try_into(op_code);
            debug!(?op, "Received operation");
            match op {
                // Note: please keep operations sorted in ascending order of their numerical op number.
                Ok(operation) => match operation {
                    Operation::IsValidPath => {
                        let path: StorePath<String> = self.reader.read_value().await?;
                        Self::handle(&self.writer, io.is_valid_path(&path)).await?
                    }
                    // Note this operation does not currently delegate to NixDaemonIO,
                    // The general idea is that we will pass relevant ClientSettings
                    // into individual NixDaemonIO method calls if the need arises.
                    // For now we just store the settings in the NixDaemon for future use.
                    Operation::SetOptions => {
                        self.client_settings = self.reader.read_value().await?;
                        Self::handle(&self.writer, async { Ok(()) }).await?
                    }
                    Operation::QueryPathInfo => {
                        let path: StorePath<String> = self.reader.read_value().await?;
                        Self::handle(&self.writer, io.query_path_info(&path)).await?
                    }
                    Operation::QueryPathFromHashPart => {
                        let hash: Bytes = self.reader.read_value().await?;
                        Self::handle(&self.writer, io.query_path_from_hash_part(&hash)).await?
                    }
                    Operation::QueryValidPaths => {
                        let query: QueryValidPaths = self.reader.read_value().await?;
                        Self::handle(&self.writer, io.query_valid_paths(&query)).await?
                    }
                    Operation::QueryValidDerivers => {
                        let path: StorePath<String> = self.reader.read_value().await?;
                        Self::handle(&self.writer, io.query_valid_derivers(&path)).await?
                    }
                    // FUTUREWORK: These are just stubs that return an empty list.
                    // It's important not to return an error for the local-overlay:// store
                    // to work properly. While it will not see certain referrers and realizations
                    // it will not fail on various operations like gc and optimize store. At the
                    // same time, returning an empty list here shouldn't break any of local-overlay store's
                    // invariants.
                    Operation::QueryReferrers | Operation::QueryRealisation => {
                        let _: String = self.reader.read_value().await?;
                        Self::handle(&self.writer, async move {
                            warn!(
                                ?operation,
                                "This operation is not implemented. Returning empty result..."
                            );
                            Ok(Vec::<StorePath<String>>::new())
                        })
                        .await?
                    }
                    Operation::AddToStoreNar => {
                        let request: AddToStoreNarRequest = self.reader.read_value().await?;
                        let minor_version = self.protocol_version.minor();
                        match minor_version {
                            ..21 => {
                                // Before protocol version 1.21, the nar is sent unframed, so we just
                                // pass the reader directly to the operation.
                                Self::handle(
                                    &self.writer,
                                    self.io.add_to_store_nar(request, &mut self.reader),
                                )
                                .await?
                            }
                            21..23 => {
                                // Protocol versions 1.21 .. 1.23 use STDERR_READ protocol, see logging.md#stderr_read.
                                Self::handle(&self.writer, async {
                                    let mut writer = self.writer.lock().await;
                                    let mut reader = StderrReadFramedReader::new(
                                        &mut self.reader,
                                        writer.deref_mut(),
                                    );
                                    self.io.add_to_store_nar(request, &mut reader).await
                                    // TODO(edef): enforce framing synchronisation
                                })
                                .await?
                            }
                            23.. => {
                                // Starting at protocol version 1.23, the framed protocol is used, see serialization.md#framed
                                let mut framed = NixFramedReader::new(&mut self.reader);

                                Self::handle(&self.writer, async {
                                    self.io.add_to_store_nar(request, &mut framed).await
                                })
                                .await?;

                                // framing desynchronisation
                                // this MUST kill the connection
                                if !framed.is_eof() {
                                    return Err(std::io::Error::new(
                                        std::io::ErrorKind::InvalidData,
                                        "payload was not fully consumed",
                                    ));
                                }
                            }
                        }
                    }
                    _ => {
                        return Err(std::io::Error::other(format!(
                            "Operation {operation:?} is not implemented"
                        )));
                    }
                },
                _ => {
                    return Err(std::io::Error::other(format!(
                        "Unknown operation code received: {op_code}"
                    )));
                }
            }
        }
    }

    /// Handles the operation and sends the response or error to the client.
    ///
    /// As per nix daemon protocol, after sending the request, the client expects zero or more
    /// log lines/activities followed by either
    /// * STDERR_LAST and the response bytes
    /// * STDERR_ERROR and the error
    ///
    /// This is a helper method, awaiting on the passed in future and then
    /// handling log lines/activities as described above.
    async fn handle<T>(
        writer: &Arc<Mutex<NixWriter<WriteHalf<RW>>>>,
        future: impl Future<Output = std::io::Result<T>>,
    ) -> Result<(), std::io::Error>
    where
        T: NixSerialize + Send,
    {
        let result = future.await;
        let mut writer = writer.lock().await;

        match result {
            Ok(r) => {
                // the protocol requires that we first indicate that we are done sending logs
                // by sending STDERR_LAST and then the response.
                writer.write_number(STDERR_LAST).await?;
                writer.write_value(&r).await?;
                writer.flush().await
            }
            Err(e) => {
                debug!(err = ?e, "IO error");
                writer.write_number(STDERR_ERROR).await?;
                writer.write_value(&NixError::new(format!("{e:?}"))).await?;
                writer.flush().await
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{io::ErrorKind, sync::Arc};

    use mockall::predicate;
    use tokio::io::AsyncWriteExt;

    use crate::{
        nix_daemon::MockNixDaemonIO,
        wire::ProtocolVersion,
        worker_protocol::{ClientSettings, WORKER_MAGIC_1, WORKER_MAGIC_2},
    };

    #[tokio::test]
    async fn test_daemon_initialization() {
        let mut builder = tokio_test::io::Builder::new();
        let test_conn = builder
            .read(&WORKER_MAGIC_1.to_le_bytes())
            .write(&WORKER_MAGIC_2.to_le_bytes())
            // Our version is 1.37
            .write(&[37, 1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            // The client's versin is 1.35
            .read(&[35, 1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            // cpu affinity
            .read(&[0; 8])
            // reservespace
            .read(&[0; 8])
            // version (size)
            .write(&[0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            // version (data == 2.18.2 + padding)
            .write(&[50, 46, 49, 56, 46, 50, 0, 0])
            // Trusted (1 == client trusted)
            .write(&[1, 0, 0, 0, 0, 0, 0, 0])
            // STDERR_LAST
            .write(&[115, 116, 108, 97, 0, 0, 0, 0]);

        let mut bytes = Vec::new();
        let mut writer = NixWriter::new(&mut bytes);
        writer
            .write_value(&ClientSettings::default())
            .await
            .unwrap();
        writer.flush().await.unwrap();

        let test_conn = test_conn
            // SetOptions op
            .read(&[19, 0, 0, 0, 0, 0, 0, 0])
            .read(&bytes)
            // STDERR_LAST
            .write(&[115, 116, 108, 97, 0, 0, 0, 0])
            .build();

        let mock = MockNixDaemonIO::new();
        let daemon = NixDaemon::initialize(Arc::new(mock), test_conn)
            .await
            .unwrap();
        assert_eq!(daemon.client_settings, ClientSettings::default());
        assert_eq!(daemon.protocol_version, ProtocolVersion::from_parts(1, 35));
    }

    async fn serialize<T>(req: &T, protocol_version: ProtocolVersion) -> Vec<u8>
    where
        T: NixSerialize + Send,
    {
        let mut result: Vec<u8> = Vec::new();
        let mut w = NixWriter::builder()
            .set_version(protocol_version)
            .build(&mut result);
        w.write_value(req).await.unwrap();
        w.flush().await.unwrap();
        result
    }

    async fn respond<T>(
        resp: &Result<T, std::io::Error>,
        protocol_version: ProtocolVersion,
    ) -> Vec<u8>
    where
        T: NixSerialize + Send,
    {
        let mut result: Vec<u8> = Vec::new();
        let mut w = NixWriter::builder()
            .set_version(protocol_version)
            .build(&mut result);
        match resp {
            Ok(value) => {
                w.write_value(&STDERR_LAST).await.unwrap();
                w.write_value(value).await.unwrap();
            }
            Err(e) => {
                w.write_value(&STDERR_ERROR).await.unwrap();
                w.write_value(&NixError::new(format!("{:?}", e)))
                    .await
                    .unwrap();
            }
        }
        w.flush().await.unwrap();
        result
    }

    #[tokio::test]
    async fn test_handle_is_valid_path_ok() {
        let version = ProtocolVersion::from_parts(1, 37);
        let (io, mut handle) = tokio_test::io::Builder::new().build_with_handle();
        let mut mock = MockNixDaemonIO::new();
        let (reader, writer) = split(io);
        let path: StorePath<String> = StorePath::<String>::from_absolute_path(
            "/nix/store/33l4p0pn0mybmqzaxfkpppyh7vx1c74p-hello-2.12.1".as_bytes(),
        )
        .unwrap();
        mock.expect_is_valid_path()
            .with(predicate::eq(path.clone()))
            .times(1)
            .returning(|_| Box::pin(async { Ok(true) }));

        handle.read(&Into::<u64>::into(Operation::IsValidPath).to_le_bytes());
        handle.read(&serialize(&path, version).await);
        handle.write(&respond(&Ok(true), version).await);
        drop(handle);

        let mut daemon = NixDaemon::new(
            Arc::new(mock),
            version,
            ClientSettings::default(),
            NixReader::new(reader),
            NixWriter::new(writer),
        );
        assert_eq!(
            ErrorKind::UnexpectedEof,
            daemon
                .handle_client()
                .await
                .expect_err("Expecting eof")
                .kind()
        );
    }

    #[tokio::test]
    async fn test_handle_is_valid_path_err() {
        let version = ProtocolVersion::from_parts(1, 37);
        let (io, mut handle) = tokio_test::io::Builder::new().build_with_handle();
        let mut mock = MockNixDaemonIO::new();
        let (reader, writer) = split(io);
        let path: StorePath<String> = StorePath::<String>::from_absolute_path(
            "/nix/store/33l4p0pn0mybmqzaxfkpppyh7vx1c74p-hello-2.12.1".as_bytes(),
        )
        .unwrap();
        mock.expect_is_valid_path()
            .with(predicate::eq(path.clone()))
            .times(1)
            .returning(|_| Box::pin(async { Err(std::io::Error::other("hello")) }));

        handle.read(&Into::<u64>::into(Operation::IsValidPath).to_le_bytes());
        handle.read(&serialize(&path, version).await);
        handle.write(&respond::<bool>(&Err(std::io::Error::other("hello")), version).await);
        drop(handle);

        let mut daemon = NixDaemon::new(
            Arc::new(mock),
            version,
            ClientSettings::default(),
            NixReader::new(reader),
            NixWriter::new(writer),
        );
        assert_eq!(
            ErrorKind::UnexpectedEof,
            daemon
                .handle_client()
                .await
                .expect_err("Expecting eof")
                .kind()
        );
    }
}
