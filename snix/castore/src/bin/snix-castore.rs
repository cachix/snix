use clap::{Parser, Subcommand};
#[cfg(any(feature = "fuse", feature = "virtiofs"))]
use snix_castore::B3Digest;
#[cfg(feature = "fs")]
use snix_castore::fs::SnixStoreFs;
#[cfg(feature = "fuse")]
use snix_castore::fs::fuse::FuseDaemon;
#[cfg(feature = "virtiofs")]
use snix_castore::fs::virtiofs::start_virtiofs_daemon;
use snix_castore::import::{archive::ingest_archive, fs::ingest_path};
use snix_castore::{Node, utils::ServiceUrls};
use std::error::Error;
use std::io::Write;
use std::path::PathBuf;
use tokio::fs::{self, File};
use tokio_tar::Archive;

#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Ingest a folder or tar archive and return its B3Digest
    Ingest {
        /// Path of the folder or tar archive to import
        #[arg(value_name = "INPUT")]
        input: PathBuf,

        #[clap(flatten)]
        service_addrs: ServiceUrls,
    },

    #[cfg(feature = "fuse")]
    /// Mount a folder using its B3Digest with FUSE
    Mount {
        /// B3Digest of the folder to mount (output of `snix-castore ingest`)
        #[arg(value_name = "DIGEST")]
        digest: String,

        /// Path to the mount point for FUSE
        #[arg(value_name = "OUTPUT")]
        output: PathBuf,

        #[clap(flatten)]
        service_addrs: ServiceUrls,
    },

    #[cfg(feature = "virtiofs")]
    /// Expose a folder using its B3Digest through a Virtiofs daemon
    Virtiofs {
        /// B3Digest of the folder to expose (output of `snix-castore ingest`)
        #[arg(value_name = "DIGEST")]
        digest: String,

        /// Path to the virtiofs socket
        #[arg(value_name = "OUTPUT")]
        output: PathBuf,

        #[clap(flatten)]
        service_addrs: ServiceUrls,
    },
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error + Send + Sync>> {
    let cli = Cli::parse();
    let tracing_handle = {
        let mut builder = snix_tracing::TracingBuilder::default();
        builder = builder.enable_progressbar();
        builder.build()?
    };
    tokio::select! {
        res = tokio::signal::ctrl_c() => {
            res?;
            if let Err(e) = tracing_handle.shutdown().await {
                eprintln!("failed to shutdown tracing: {e}");
            }
            Ok(())
        },
        res = async {
            match cli.command {
                Commands::Ingest {
                    input,
                    service_addrs,
                } => {
                    let blob_service = snix_castore::blobservice::from_addr(&service_addrs.blob_service_addr).await?;
                    let directory_service =
                        snix_castore::directoryservice::from_addr(&service_addrs.directory_service_addr).await?;
                    let metadata = fs::metadata(&input).await?;
                    let node = if metadata.is_dir() {
                        ingest_path::<_, _, _, &[u8]>(&blob_service, &directory_service, &input, None)
                            .await?
                    } else {
                        let file = File::open(&input).await?;
                        let archive_instance = Archive::new(file);
                        ingest_archive(blob_service.clone(), &directory_service, archive_instance).await?
                    };
                    let digest = match node {
                        Node::Directory { digest, .. } => digest,
                        _ => return Err("Expected a directory node".into()),
                    };
                    let mut stdout = tracing_handle.get_stdout_writer();
                    writeln!(stdout, "{digest}")?;
                }
                #[cfg(feature = "fuse")]
                Commands::Mount {
                    digest,
                    output,
                    service_addrs,
                } => {
                    let blob_service = snix_castore::blobservice::from_addr(&service_addrs.blob_service_addr).await?;
                    let directory_service =
                        snix_castore::directoryservice::from_addr(&service_addrs.directory_service_addr).await?;
                    let digest: B3Digest = digest.parse()?;
                    let root_nodes_provider = directory_service
                        .get(&digest)
                        .await?
                        .ok_or("Root nodes provider not found")?;
                    let fuse_daemon = tokio::task::spawn_blocking(move || {
                        let fs = SnixStoreFs::new(
                            blob_service,
                            directory_service,
                            root_nodes_provider,
                            true,
                            true,
                        );
                        FuseDaemon::new(fs, &output, 4, true)
                    })
                    .await??;
                    tokio::spawn({
                        let fuse_daemon = fuse_daemon.clone();
                        async move {
                            tokio::signal::ctrl_c().await.unwrap();
                            tokio::task::spawn_blocking(move || fuse_daemon.unmount()).await??;
                            Ok::<_, std::io::Error>(())
                        }
                    });
                    tokio::task::spawn_blocking(move || fuse_daemon.wait()).await?;
                }
                #[cfg(feature = "virtiofs")]
                Commands::Virtiofs {
                    digest,
                    output,
                    service_addrs,
                } => {
                    let blob_service = snix_castore::blobservice::from_addr(&service_addrs.blob_service_addr).await?;
                    let directory_service =
                        snix_castore::directoryservice::from_addr(&service_addrs.directory_service_addr).await?;
                    let digest: B3Digest = digest.parse()?;
                    let root_nodes_provider = directory_service
                        .get(&digest)
                        .await?
                        .ok_or("Root nodes provider not found")?;
                    tokio::task::spawn_blocking(move || {
                        let fs = SnixStoreFs::new(
                            blob_service,
                            directory_service,
                            root_nodes_provider,
                            true,
                            true,
                        );
                        start_virtiofs_daemon(fs, &output)
                    })
                    .await??;
                }
            }
            Ok(())
        } => {
            if let Err(e) = tracing_handle.shutdown().await {
                eprintln!("failed to shutdown tracing: {e}");
            }
            res
        }
    }
}
