use std::collections::HashMap;
use std::sync::Arc;
use url::Url;

use crate::blobservice::BlobService;
use crate::composition::{
    with_registry, Composition, DeserializeWithRegistry, ServiceBuilder, REG,
};
use crate::directoryservice::DirectoryService;

#[derive(serde::Deserialize, Default)]
pub struct CompositionConfigs {
    pub blobservices:
        HashMap<String, DeserializeWithRegistry<Box<dyn ServiceBuilder<Output = dyn BlobService>>>>,
    pub directoryservices: HashMap<
        String,
        DeserializeWithRegistry<Box<dyn ServiceBuilder<Output = dyn DirectoryService>>>,
    >,
}

/// Provides a set of clap arguments to configure tvix-castore services.
///
/// This particular variant has defaults tailored for usecases accessing data
/// directly locally, like the `tvix-store daemon` command.
#[derive(clap::Parser, Clone)]
#[group(id = "CastoreServiceUrls")]
pub struct ServiceUrls {
    #[arg(
        long,
        env,
        default_value = "objectstore+file:///var/lib/tvix-store/blobs.object_store"
    )]
    pub blob_service_addr: String,

    #[arg(
        long,
        env,
        default_value = "redb:///var/lib/tvix-store/directories.redb"
    )]
    pub directory_service_addr: String,

    /// Path to a TOML file describing the way the services should be composed
    /// Experimental because the format is not final.
    /// If specified, the other service addrs are ignored.
    #[cfg(feature = "xp-composition-cli")]
    #[arg(long, env)]
    experimental_store_composition: Option<String>,
}

/// Provides a set of clap arguments to configure tvix-castore services.
///
/// This particular variant has defaults tailored for usecases accessing data
/// from another running tvix daemon, via gRPC.
#[derive(clap::Parser, Clone)]
#[group(id = "CastoreServiceUrlsGrpc")]
pub struct ServiceUrlsGrpc {
    #[arg(long, env, default_value = "grpc+http://[::1]:8000")]
    blob_service_addr: String,

    #[arg(long, env, default_value = "grpc+http://[::1]:8000")]
    directory_service_addr: String,

    #[cfg(feature = "xp-composition-cli")]
    #[arg(long, env)]
    experimental_store_composition: Option<String>,
}

/// Provides a set of clap arguments to configure tvix-castore services.
///
/// This particular variant has defaults tailored for usecases keeping all data
/// in memory.
/// It's currently used in tvix-cli, as we don't really care about persistency
/// there yet, and using something else here might make some perf output harder
/// to interpret.
#[derive(clap::Parser, Clone)]
#[group(id = "CastoreServiceUrlsMemory")]
pub struct ServiceUrlsMemory {
    #[arg(long, env, default_value = "memory://")]
    blob_service_addr: String,

    #[arg(long, env, default_value = "memory://")]
    directory_service_addr: String,

    #[cfg(feature = "xp-composition-cli")]
    #[arg(long, env)]
    experimental_store_composition: Option<String>,
}

impl From<ServiceUrlsGrpc> for ServiceUrls {
    fn from(urls: ServiceUrlsGrpc) -> ServiceUrls {
        ServiceUrls {
            blob_service_addr: urls.blob_service_addr,
            directory_service_addr: urls.directory_service_addr,
            #[cfg(feature = "xp-composition-cli")]
            experimental_store_composition: urls.experimental_store_composition,
        }
    }
}

impl From<ServiceUrlsMemory> for ServiceUrls {
    fn from(urls: ServiceUrlsMemory) -> ServiceUrls {
        ServiceUrls {
            blob_service_addr: urls.blob_service_addr,
            directory_service_addr: urls.directory_service_addr,
            #[cfg(feature = "xp-composition-cli")]
            experimental_store_composition: urls.experimental_store_composition,
        }
    }
}

/// Deserializes service addresses into composition config, configuring each
/// service as the single "root".
/// If the `xp-composition-cli` feature is enabled, and a file specified in the
/// `--experimental-store-composition` parameter, this is used instead.
pub async fn addrs_to_configs(
    urls: impl Into<ServiceUrls>,
) -> Result<CompositionConfigs, Box<dyn std::error::Error + Send + Sync>> {
    let urls: ServiceUrls = urls.into();

    #[cfg(feature = "xp-composition-cli")]
    if let Some(conf_path) = urls.experimental_store_composition {
        let conf_text = tokio::fs::read_to_string(conf_path).await?;
        return Ok(with_registry(&REG, || toml::from_str(&conf_text))?);
    }

    let mut configs: CompositionConfigs = Default::default();

    let blob_service_url = Url::parse(&urls.blob_service_addr)?;
    let directory_service_url = Url::parse(&urls.directory_service_addr)?;
    configs.blobservices.insert(
        "root".into(),
        with_registry(&REG, || blob_service_url.try_into())?,
    );
    configs.directoryservices.insert(
        "root".into(),
        with_registry(&REG, || directory_service_url.try_into())?,
    );
    Ok(configs)
}

/// Construct the castore handles from their addrs.
pub async fn construct_services(
    urls: impl Into<ServiceUrls>,
) -> Result<
    (Arc<dyn BlobService>, Arc<dyn DirectoryService>),
    Box<dyn std::error::Error + Send + Sync>,
> {
    let configs = addrs_to_configs(urls).await?;
    construct_services_from_configs(configs).await
}

/// Construct the castore handles from their addrs.
pub async fn construct_services_from_configs(
    configs: CompositionConfigs,
) -> Result<
    (Arc<dyn BlobService>, Arc<dyn DirectoryService>),
    Box<dyn std::error::Error + Send + Sync>,
> {
    let mut comp = Composition::new(&REG);

    comp.extend(configs.blobservices);
    comp.extend(configs.directoryservices);

    let blob_service: Arc<dyn BlobService> = comp.build("root").await?;
    let directory_service: Arc<dyn DirectoryService> = comp.build("root").await?;

    Ok((blob_service, directory_service))
}
