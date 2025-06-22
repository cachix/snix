use super::{PathInfo, PathInfoService};
use crate::proto;
use async_stream::try_stream;
use data_encoding::BASE64;
use futures::stream::BoxStream;
use prost::Message;
use redb::{Database, ReadableTable, TableDefinition};
use snix_castore::{
    Error,
    composition::{CompositionContext, ServiceBuilder},
};
use std::{path::PathBuf, sync::Arc};
use tonic::async_trait;
use tracing::{instrument, warn};

const PATHINFO_TABLE: TableDefinition<[u8; 20], Vec<u8>> = TableDefinition::new("pathinfo");

/// PathInfoService implementation using redb under the hood.
/// redb stores all of its data in a single file with a K/V pointing from a path's output hash to
/// its corresponding protobuf-encoded PathInfo.
pub struct RedbPathInfoService {
    instance_name: String,
    // We wrap db in an Arc to be able to move it into spawn_blocking,
    // as discussed in https://github.com/cberner/redb/issues/789
    db: Arc<Database>,
}

impl RedbPathInfoService {
    /// Constructs a new instance using the specified file system path for
    /// storage.
    pub async fn new(instance_name: String, path: PathBuf) -> Result<Self, Error> {
        if path == PathBuf::from("/") {
            return Err(Error::StorageError(
                "cowardly refusing to open / with redb".to_string(),
            ));
        }

        let db = tokio::task::spawn_blocking(|| -> Result<_, redb::Error> {
            let db = redb::Database::create(path)?;
            create_schema(&db)?;
            Ok(db)
        })
        .await??;

        Ok(Self {
            instance_name,
            db: Arc::new(db),
        })
    }

    /// Constructs a new instance using the in-memory backend.
    pub fn new_temporary(instance_name: String) -> Result<Self, Error> {
        let db =
            redb::Database::builder().create_with_backend(redb::backends::InMemoryBackend::new())?;

        create_schema(&db)?;

        Ok(Self {
            instance_name,
            db: Arc::new(db),
        })
    }
}

/// Ensures all tables are present.
/// Opens a write transaction and calls open_table on PATHINFO_TABLE, which will
/// create it if not present.
fn create_schema(db: &redb::Database) -> Result<(), redb::Error> {
    let txn = db.begin_write()?;
    txn.open_table(PATHINFO_TABLE)?;
    txn.commit()?;

    Ok(())
}

#[async_trait]
impl PathInfoService for RedbPathInfoService {
    #[instrument(level = "trace", skip_all, fields(path_info.digest = BASE64.encode(&digest), instance_name = %self.instance_name))]
    async fn get(&self, digest: [u8; 20]) -> Result<Option<PathInfo>, Error> {
        let db = self.db.clone();

        tokio::task::spawn_blocking({
            move || {
                let txn = db.begin_read()?;
                let table = txn.open_table(PATHINFO_TABLE)?;
                match table.get(digest)? {
                    Some(pathinfo_bytes) => Ok(Some(
                        proto::PathInfo::decode(pathinfo_bytes.value().as_slice())
                            .map_err(|e| {
                                warn!(err=%e, "failed to decode stored PathInfo");
                                Error::StorageError("failed to decode stored PathInfo".to_string())
                            })?
                            .try_into()
                            .map_err(|e| Error::StorageError(format!("Invalid path info: {e}")))?,
                    )),
                    None => Ok(None),
                }
            }
        })
        .await?
    }

    #[instrument(level = "trace", skip_all, fields(path_info.root_node = ?path_info.node, instance_name = %self.instance_name))]
    async fn put(&self, path_info: PathInfo) -> Result<PathInfo, Error> {
        let db = self.db.clone();

        tokio::task::spawn_blocking({
            let path_info = path_info.clone();
            move || -> Result<(), Error> {
                let txn = db.begin_write()?;
                {
                    let mut table = txn.open_table(PATHINFO_TABLE)?;
                    table
                        .insert(
                            *path_info.store_path.digest(),
                            proto::PathInfo::from(path_info).encode_to_vec(),
                        )
                        .map_err(|e| {
                            warn!(err=%e, "failed to insert PathInfo");
                            Error::StorageError("failed to insert PathInfo".to_string())
                        })?;
                }
                Ok(txn.commit()?)
            }
        })
        .await??;

        Ok(path_info)
    }

    fn list(&self) -> BoxStream<'static, Result<PathInfo, Error>> {
        let db = self.db.clone();
        Box::pin(try_stream! {
            let read_txn = db.begin_read()?;
            let table = read_txn.open_table(PATHINFO_TABLE)?;

            for elem in table.iter()? {
                let elem = elem?;
                yield {
                    let path_info_proto = proto::PathInfo::decode(
                        elem.1.value().as_slice(),
                    )
                    .map_err(|e| {
                        warn!(err=%e, "invalid PathInfo");
                        Error::StorageError("invalid PathInfo".to_string())
                    })?;
                    PathInfo::try_from(path_info_proto).map_err(|e| {
                        Error::StorageError(format!("Invalid path info: {e}"))
                    })?
                }
            }
        })
    }
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RedbPathInfoServiceConfig {
    is_temporary: bool,
    #[serde(default)]
    /// required when is_temporary = false
    path: Option<PathBuf>,
}

impl TryFrom<url::Url> for RedbPathInfoServiceConfig {
    type Error = Box<dyn std::error::Error + Send + Sync>;
    fn try_from(url: url::Url) -> Result<Self, Self::Error> {
        // redb doesn't support host, and a path can be provided (otherwise it'll live in memory only)
        if url.has_host() {
            return Err(Error::StorageError("no host allowed".to_string()).into());
        }

        Ok(if url.path().is_empty() {
            RedbPathInfoServiceConfig {
                is_temporary: true,
                path: None,
            }
        } else {
            RedbPathInfoServiceConfig {
                is_temporary: false,
                path: Some(url.path().into()),
            }
        })
    }
}

#[async_trait]
impl ServiceBuilder for RedbPathInfoServiceConfig {
    type Output = dyn PathInfoService;
    async fn build<'a>(
        &'a self,
        instance_name: &str,
        _context: &CompositionContext,
    ) -> Result<Arc<dyn PathInfoService>, Box<dyn std::error::Error + Send + Sync + 'static>> {
        match self {
            RedbPathInfoServiceConfig {
                is_temporary: true,
                path: None,
            } => Ok(Arc::new(RedbPathInfoService::new_temporary(
                instance_name.to_string(),
            )?)),
            RedbPathInfoServiceConfig {
                is_temporary: true,
                path: Some(_),
            } => Err(
                Error::StorageError("Temporary RedbPathInfoService can not have path".into())
                    .into(),
            ),
            RedbPathInfoServiceConfig {
                is_temporary: false,
                path: None,
            } => Err(Error::StorageError("RedbPathInfoService is missing path".into()).into()),
            RedbPathInfoServiceConfig {
                is_temporary: false,
                path: Some(path),
            } => Ok(Arc::new(
                RedbPathInfoService::new(instance_name.to_string(), path.to_owned()).await?,
            )),
        }
    }
}
