use std::{
    collections::HashMap,
    pin::Pin,
    sync::Arc,
    task::{self, Poll},
};
use tokio::io::{self, AsyncWrite};

use tvix_castore::utils as castore_utils;
use tvix_castore::{blobservice::BlobService, directoryservice::DirectoryService};
use url::Url;

use crate::composition::REG;
use crate::nar::{NarCalculationService, SimpleRenderer};
use crate::pathinfoservice::PathInfoService;
use tvix_castore::composition::{
    with_registry, Composition, DeserializeWithRegistry, ServiceBuilder,
};

#[derive(serde::Deserialize, Default)]
pub struct CompositionConfigs {
    pub blobservices:
        HashMap<String, DeserializeWithRegistry<Box<dyn ServiceBuilder<Output = dyn BlobService>>>>,
    pub directoryservices: HashMap<
        String,
        DeserializeWithRegistry<Box<dyn ServiceBuilder<Output = dyn DirectoryService>>>,
    >,
    pub pathinfoservices: HashMap<
        String,
        DeserializeWithRegistry<Box<dyn ServiceBuilder<Output = dyn PathInfoService>>>,
    >,
}

/// Provides a set of clap arguments to configure tvix-\[ca\]store services.
///
/// This particular variant has defaults tailored for usecases accessing data
/// directly locally, like the `tvix-store daemon` command.
#[derive(clap::Parser, Clone)]
#[group(id = "StoreServiceUrls")]
pub struct ServiceUrls {
    #[clap(flatten)]
    castore_service_addrs: castore_utils::ServiceUrls,

    #[arg(long, env, default_value = "redb:///var/lib/tvix-store/pathinfo.redb")]
    path_info_service_addr: String,

    /// Path to a TOML file describing the way the services should be composed
    /// Experimental because the format is not final.
    /// If specified, the other service addrs are ignored.
    #[cfg(feature = "xp-composition-cli")]
    #[arg(long, env)]
    experimental_store_composition: Option<String>,
}

/// Provides a set of clap arguments to configure tvix-\[ca\]store services.
///
/// This particular variant has defaults tailored for usecases accessing data
/// from another running tvix daemon, via gRPC.
#[derive(clap::Parser, Clone)]
#[group(id = "StoreServiceUrlsGrpc")]
pub struct ServiceUrlsGrpc {
    #[clap(flatten)]
    castore_service_addrs: castore_utils::ServiceUrlsGrpc,

    #[arg(long, env, default_value = "grpc+http://[::1]:8000")]
    path_info_service_addr: String,

    #[cfg(feature = "xp-composition-cli")]
    #[arg(long, env)]
    experimental_store_composition: Option<String>,
}

/// Provides a set of clap arguments to configure tvix-\[ca\]store services.
///
/// This particular variant has defaults tailored for usecases keeping all data
/// in memory.
/// It's currently used in tvix-cli, as we don't really care about persistency
/// there yet, and using something else here might make some perf output harder
/// to interpret.
#[derive(clap::Parser, Clone)]
#[group(id = "StoreServiceUrlsMemory")]
pub struct ServiceUrlsMemory {
    #[clap(flatten)]
    castore_service_addrs: castore_utils::ServiceUrlsMemory,

    #[arg(long, env, default_value = "memory://")]
    path_info_service_addr: String,

    #[cfg(feature = "xp-composition-cli")]
    #[arg(long, env)]
    experimental_store_composition: Option<String>,
}

impl From<ServiceUrlsGrpc> for ServiceUrls {
    fn from(urls: ServiceUrlsGrpc) -> ServiceUrls {
        ServiceUrls {
            castore_service_addrs: urls.castore_service_addrs.into(),
            path_info_service_addr: urls.path_info_service_addr,
            #[cfg(feature = "xp-composition-cli")]
            experimental_store_composition: urls.experimental_store_composition,
        }
    }
}

impl From<ServiceUrlsMemory> for ServiceUrls {
    fn from(urls: ServiceUrlsMemory) -> ServiceUrls {
        ServiceUrls {
            castore_service_addrs: urls.castore_service_addrs.into(),
            path_info_service_addr: urls.path_info_service_addr,
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

    let blob_service_url = Url::parse(&urls.castore_service_addrs.blob_service_addr)?;
    let directory_service_url = Url::parse(&urls.castore_service_addrs.directory_service_addr)?;
    let path_info_service_url = Url::parse(&urls.path_info_service_addr)?;

    configs.blobservices.insert(
        "root".into(),
        with_registry(&REG, || blob_service_url.try_into())?,
    );
    configs.directoryservices.insert(
        "root".into(),
        with_registry(&REG, || directory_service_url.try_into())?,
    );
    configs.pathinfoservices.insert(
        "root".into(),
        with_registry(&REG, || path_info_service_url.try_into())?,
    );

    Ok(configs)
}

/// Construct the store handles from their addrs.
pub async fn construct_services(
    urls: impl Into<ServiceUrls>,
) -> Result<
    (
        Arc<dyn BlobService>,
        Arc<dyn DirectoryService>,
        Arc<dyn PathInfoService>,
        Box<dyn NarCalculationService>,
    ),
    Box<dyn std::error::Error + Send + Sync>,
> {
    let configs = addrs_to_configs(urls).await?;
    construct_services_from_configs(configs).await
}

/// Construct the store handles from their addrs.
pub async fn construct_services_from_configs(
    configs: CompositionConfigs,
) -> Result<
    (
        Arc<dyn BlobService>,
        Arc<dyn DirectoryService>,
        Arc<dyn PathInfoService>,
        Box<dyn NarCalculationService>,
    ),
    Box<dyn std::error::Error + Send + Sync>,
> {
    let mut comp = Composition::new(&REG);

    comp.extend(configs.blobservices);
    comp.extend(configs.directoryservices);
    comp.extend(configs.pathinfoservices);

    let blob_service: Arc<dyn BlobService> = comp.build("root").await?;
    let directory_service: Arc<dyn DirectoryService> = comp.build("root").await?;
    let path_info_service: Arc<dyn PathInfoService> = comp.build("root").await?;

    // HACK: The grpc client also implements NarCalculationService, and we
    // really want to use it (otherwise we'd need to fetch everything again for hashing).
    // Until we revamped store composition and config, detect this special case here.
    let nar_calculation_service: Box<dyn NarCalculationService> = path_info_service
        .nar_calculation_service()
        .unwrap_or_else(|| {
            Box::new(SimpleRenderer::new(
                blob_service.clone(),
                directory_service.clone(),
            ))
        });

    Ok((
        blob_service,
        directory_service,
        path_info_service,
        nar_calculation_service,
    ))
}

/// The inverse of [tokio_util::io::SyncIoBridge].
/// Don't use this with anything that actually does blocking I/O.
pub struct AsyncIoBridge<T>(pub T);

impl<W: std::io::Write + Unpin> AsyncWrite for AsyncIoBridge<W> {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut task::Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Poll::Ready(self.get_mut().0.write(buf))
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut task::Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(self.get_mut().0.flush())
    }

    fn poll_shutdown(
        self: Pin<&mut Self>,
        _cx: &mut task::Context<'_>,
    ) -> Poll<Result<(), io::Error>> {
        Poll::Ready(Ok(()))
    }
}
