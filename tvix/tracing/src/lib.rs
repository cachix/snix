use indicatif::ProgressStyle;
use std::sync::LazyLock;
use tokio::sync::{mpsc, oneshot};
use tracing::level_filters::LevelFilter;
use tracing_indicatif::{
    filter::IndicatifFilter, util::FilteredFormatFields, writer, IndicatifLayer, IndicatifWriter,
};
use tracing_subscriber::{
    layer::{Identity, SubscriberExt},
    util::SubscriberInitExt as _,
    EnvFilter, Layer, Registry,
};

#[cfg(feature = "otlp")]
use opentelemetry::{trace::Tracer, KeyValue};
#[cfg(feature = "otlp")]
use opentelemetry_sdk::{
    propagation::TraceContextPropagator,
    resource::{ResourceDetector, SdkProvidedResourceDetector},
    Resource,
};
#[cfg(feature = "tracy")]
use tracing_tracy::TracyLayer;

pub mod propagate;

pub static PB_PROGRESS_STYLE: LazyLock<ProgressStyle> = LazyLock::new(|| {
    ProgressStyle::with_template(
        "{span_child_prefix} {wide_msg} {bar:10} ({elapsed}) {pos:>7}/{len:7}",
    )
    .expect("invalid progress template")
});
pub static PB_TRANSFER_STYLE: LazyLock<ProgressStyle> = LazyLock::new(|| {
    ProgressStyle::with_template(
        "{span_child_prefix} {wide_msg} {binary_bytes:>7}/{binary_total_bytes:7}@{decimal_bytes_per_sec} ({elapsed}) {bar:10} "
    )
    .expect("invalid progress template")
});
pub static PB_SPINNER_STYLE: LazyLock<ProgressStyle> = LazyLock::new(|| {
    ProgressStyle::with_template(
        "{span_child_prefix}{spinner} {wide_msg} ({elapsed}) {pos:>7}/{len:7}",
    )
    .expect("invalid progress template")
});

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error(transparent)]
    Init(#[from] tracing_subscriber::util::TryInitError),

    #[error(transparent)]
    MpscSend(#[from] mpsc::error::SendError<oneshot::Sender<()>>),

    #[error(transparent)]
    OneshotRecv(#[from] oneshot::error::RecvError),
}

#[derive(Clone)]
pub struct TracingHandle {
    #[cfg(feature = "otlp")]
    /// A channel that can be sent to whenever traces/metrics should be flushed.
    /// Once flushing is finished, the sent oneshot::Sender will get triggered.
    flush_tx: Option<mpsc::Sender<oneshot::Sender<()>>>,

    stdout_writer: IndicatifWriter<writer::Stdout>,
    stderr_writer: IndicatifWriter<writer::Stderr>,
}

impl TracingHandle {
    /// Returns a writer for [std::io::Stdout] that ensures its output will not be clobbered by
    /// active progress bars.
    ///
    /// Instead of `println!(...)` prefer `writeln!(handle.get_stdout_writer(), ...)`
    pub fn get_stdout_writer(&self) -> IndicatifWriter<writer::Stdout> {
        // clone is fine here because its only a wrapper over an `Arc`
        self.stdout_writer.clone()
    }

    /// Returns a writer for [std::io::Stderr] that ensures its output will not be clobbered by
    /// active progress bars.
    ///
    /// Instead of `println!(...)` prefer `writeln!(handle.get_stderr_writer(), ...)`.
    pub fn get_stderr_writer(&self) -> IndicatifWriter<writer::Stderr> {
        // clone is fine here because its only a wrapper over an `Arc`
        self.stderr_writer.clone()
    }

    /// This will flush possible attached tracing providers, e.g. otlp exported, if enabled.
    /// If there is none enabled this will result in a noop.
    ///
    /// It will wait until the flush is complete.
    pub async fn flush(&self) -> Result<(), Error> {
        #[cfg(feature = "otlp")]
        if let Some(flush_tx) = &self.flush_tx {
            let (tx, rx) = oneshot::channel();
            // Request the flush.
            flush_tx.send(tx).await?;

            // Wait for it to be done.
            rx.await?;
        }
        Ok(())
    }

    /// This will flush all all attached tracing providers and will wait until the flush is completed.
    /// If no tracing providers like otlp are attached then this will be a noop.
    ///
    /// This should only be called on a regular shutdown.
    /// If you correctly need to shutdown tracing on ctrl_c use [force_shutdown](#method.force_shutdown)
    /// otherwise you will get otlp errors.
    pub async fn shutdown(&self) -> Result<(), Error> {
        self.flush().await
    }

    /// This will flush all all attached tracing providers and will wait until the flush is completed.
    /// After this it will do some other necessary cleanup.
    /// If no tracing providers like otlp are attached then this will be a noop.
    ///
    /// This should only be used if the tool received an ctrl_c otherwise you will get otlp errors.
    /// If you need to shutdown tracing on a regular exit, you should use the [shutdown](#method.shutdown)
    /// method.
    pub async fn force_shutdown(&self) -> Result<(), Error> {
        self.flush().await?;

        #[cfg(feature = "otlp")]
        {
            // Because of a bug within otlp we currently have to use spawn_blocking otherwise
            // calling `shutdown_tracer_provider` can block forever. See
            // https://github.com/open-telemetry/opentelemetry-rust/issues/1395#issuecomment-1953280335
            //
            // This still throws an error, if the tool exits regularly: "OpenTelemetry trace error
            // occurred. oneshot canceled", but not having this leads to errors if we cancel with
            // ctrl_c.
            // So this should right now only be used on ctrl_c, for a regular exit use the
            // [shutdown](#shutdown) method
            let _ = tokio::task::spawn_blocking(move || {
                opentelemetry::global::shutdown_tracer_provider();
            })
            .await;
        }

        Ok(())
    }
}

#[must_use = "Don't forget to call build() to enable tracing."]
#[derive(Default)]
pub struct TracingBuilder {
    progess_bar: bool,

    #[cfg(feature = "otlp")]
    service_name: Option<&'static str>,
}

impl TracingBuilder {
    #[cfg(feature = "otlp")]
    /// Enable otlp by setting a custom service_name
    pub fn enable_otlp(mut self, service_name: &'static str) -> TracingBuilder {
        self.service_name = Some(service_name);
        self
    }

    /// Enable progress bar layer, default is disabled
    pub fn enable_progressbar(mut self) -> TracingBuilder {
        self.progess_bar = true;
        self
    }

    /// This will setup tracing based on the configuration passed in.
    /// It will setup a stderr writer output layer and configure EnvFilter to honor RUST_LOG.
    /// The EnvFilter will be applied to all configured layers, also otlp.
    ///
    /// It will also configure otlp if the feature is enabled and a service_name was provided. It
    /// will then correctly setup a channel which is later used for flushing the provider.
    pub fn build(self) -> Result<TracingHandle, Error> {
        self.build_with_additional(Identity::new())
    }

    /// Similar to `build()` but allows passing in an additional tracing [`Layer`].
    ///
    /// This method is generic over the `Layer` to avoid the runtime cost of dynamic dispatch.
    /// While it only allows passing a single `Layer`, it can be composed of multiple ones:
    ///
    /// ```ignore
    /// build_with_additional(
    ///   fmt::layer()
    ///     .and_then(some_other_layer)
    ///     .and_then(yet_another_layer)
    ///     .with_filter(my_filter)
    /// )
    /// ```
    /// [`Layer`]: tracing_subscriber::layer::Layer
    pub fn build_with_additional<L>(self, additional_layer: L) -> Result<TracingHandle, Error>
    where
        L: Layer<Registry> + Send + Sync + 'static,
    {
        // Set up the tracing subscriber.
        let indicatif_layer = IndicatifLayer::new().with_progress_style(PB_SPINNER_STYLE.clone());
        let stdout_writer = indicatif_layer.get_stdout_writer();
        let stderr_writer = indicatif_layer.get_stderr_writer();

        let layered = tracing_subscriber::fmt::Layer::new()
            .fmt_fields(FilteredFormatFields::new(
                tracing_subscriber::fmt::format::DefaultFields::new(),
                |field| field.name() != "indicatif.pb_show",
            ))
            .with_writer(indicatif_layer.get_stderr_writer())
            .compact()
            .and_then((self.progess_bar).then(|| {
                indicatif_layer.with_filter(
                    // only show progress for spans with indicatif.pb_show field being set
                    IndicatifFilter::new(false),
                )
            }));
        #[cfg(feature = "tracy")]
        let layered = layered.and_then(TracyLayer::default());

        #[cfg(feature = "otlp")]
        let mut flush_tx: Option<mpsc::Sender<oneshot::Sender<()>>> = None;

        // Setup otlp if a service_name is configured
        #[cfg(feature = "otlp")]
        let layered = layered.and_then({
            if let Some(service_name) = self.service_name {
                // register a text map propagator for trace propagation
                opentelemetry::global::set_text_map_propagator(TraceContextPropagator::new());

                let (tracer, meter_provider, sender) =
                    gen_otlp_tracer_meter_provider(service_name.to_string());

                flush_tx = Some(sender);

                // Register the returned meter provider as the global one.
                // FUTUREWORK: store in the struct and provide getter instead?
                opentelemetry::global::set_meter_provider(meter_provider);

                // Create a tracing layer with the configured tracer
                Some(tracing_opentelemetry::layer().with_tracer(tracer))
            } else {
                None
            }
        });

        let layered = layered.with_filter(
            EnvFilter::builder()
                .with_default_directive(LevelFilter::INFO.into())
                .from_env()
                .expect("invalid RUST_LOG"),
        );

        tracing_subscriber::registry()
            // TODO: if additional_layer has global filters, there is a risk that it will disable the "default" ones,
            // while it could be solved by registering `additional_layer` last, it requires boxing `additional_layer`.
            .with(additional_layer)
            .with(layered)
            .try_init()?;

        Ok(TracingHandle {
            #[cfg(feature = "otlp")]
            flush_tx,
            stdout_writer,
            stderr_writer,
        })
    }
}

#[cfg(feature = "otlp")]
fn gen_resources(service_name: String) -> Resource {
    // use SdkProvidedResourceDetector.detect to detect resources,
    // but replace the default service name with our default.
    // https://github.com/open-telemetry/opentelemetry-rust/issues/1298

    let resources = SdkProvidedResourceDetector.detect(std::time::Duration::from_secs(0));
    // SdkProvidedResourceDetector currently always sets
    // `service.name`, but we don't like its default.
    if resources.get("service.name".into()).unwrap() == "unknown_service".into() {
        resources.merge(&Resource::new([KeyValue::new(
            opentelemetry_semantic_conventions::resource::SERVICE_NAME,
            service_name,
        )]))
    } else {
        resources
    }
}

/// Returns an OTLP tracer, and the TX part of a channel, which can be used
/// to request flushes (and signal back the completion of the flush).
#[cfg(feature = "otlp")]
fn gen_tracer_provider(
    service_name: String,
) -> Result<opentelemetry_sdk::trace::TracerProvider, opentelemetry::trace::TraceError> {
    use opentelemetry_otlp::SpanExporter;
    use opentelemetry_sdk::{runtime, trace::TracerProvider};

    let exporter = SpanExporter::builder().with_tonic().build()?;

    let tracer_provider = TracerProvider::builder()
        .with_batch_exporter(exporter, runtime::Tokio)
        .with_config(
            opentelemetry_sdk::trace::Config::default().with_resource(gen_resources(service_name)),
        )
        .build();

    // Unclear how to configure this
    // let batch_config = BatchConfigBuilder::default()
    //     // the default values for `max_export_batch_size` is set to 512, which we will fill
    //     // pretty quickly, which will then result in an export. We want to make sure that
    //     // the export is only done once the schedule is met and not as soon as 512 spans
    //     // are collected.
    //     .with_max_export_batch_size(4096)
    //     // analog to default config `max_export_batch_size * 4`
    //     .with_max_queue_size(4096 * 4)
    //     // only force an export to the otlp collector every 10 seconds to reduce the amount
    //     // of error messages if an otlp collector is not available
    //     .with_scheduled_delay(std::time::Duration::from_secs(10))
    //     .build();

    // use opentelemetry_sdk::trace::BatchSpanProcessor;
    // let batch_span_processor = BatchSpanProcessor::builder(exporter, runtime::Tokio)
    //     .with_batch_config(batch_config)
    //     .build();

    Ok(tracer_provider)
}

#[cfg(feature = "otlp")]
fn gen_meter_provider(
    service_name: String,
) -> Result<opentelemetry_sdk::metrics::SdkMeterProvider, opentelemetry_sdk::metrics::MetricError> {
    use std::time::Duration;

    use opentelemetry_otlp::WithExportConfig;
    use opentelemetry_sdk::{
        metrics::{PeriodicReader, SdkMeterProvider},
        runtime,
    };
    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_tonic()
        .with_timeout(Duration::from_secs(10))
        .build()?;

    Ok(SdkMeterProvider::builder()
        .with_reader(
            PeriodicReader::builder(exporter, runtime::Tokio)
                .with_interval(Duration::from_secs(3))
                .with_timeout(Duration::from_secs(10))
                .build(),
        )
        .with_resource(gen_resources(service_name))
        .build())
}

/// Returns an OTLP tracer, and a meter provider, as well as the TX part
/// of a channel, which can be used to request flushes (and signal back the
/// completion of the flush).
#[cfg(feature = "otlp")]
fn gen_otlp_tracer_meter_provider(
    service_name: String,
) -> (
    impl Tracer + tracing_opentelemetry::PreSampledTracer,
    opentelemetry_sdk::metrics::SdkMeterProvider,
    mpsc::Sender<oneshot::Sender<()>>,
) {
    use opentelemetry::trace::TracerProvider;
    let tracer_provider =
        gen_tracer_provider(service_name.clone()).expect("Unable to configure trace provider");
    let meter_provider =
        gen_meter_provider(service_name).expect("Unable to configure meter provider");

    // tracer_provider needs to be kept around so we can request flushes later.
    let tracer = tracer_provider.tracer("tvix");

    // Set up a channel for flushing trace providers later
    let (flush_tx, mut flush_rx) = mpsc::channel::<oneshot::Sender<()>>(16);

    // Spawning a task that listens on rx for any message. Once we receive a message we
    // correctly call flush on the tracer_provider.
    tokio::spawn({
        let meter_provider = meter_provider.clone();

        async move {
            while let Some(m) = flush_rx.recv().await {
                // Because of a bug within otlp we currently have to use spawn_blocking
                // otherwise will calling `force_flush` block forever, especially if the
                // tool was closed with ctrl_c. See
                // https://github.com/open-telemetry/opentelemetry-rust/issues/1395#issuecomment-1953280335
                let _ = tokio::task::spawn_blocking({
                    let tracer_provider = tracer_provider.clone();
                    let meter_provider = meter_provider.clone();

                    move || {
                        tracer_provider.force_flush();
                        if let Err(e) = meter_provider.force_flush() {
                            eprintln!("failed to flush meter provider: {}", e);
                        }
                    }
                })
                .await;
                let _ = m.send(());
            }
        }
    });

    (tracer, meter_provider, flush_tx)
}
