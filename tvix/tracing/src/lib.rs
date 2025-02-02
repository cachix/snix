use indicatif::ProgressStyle;
use std::sync::LazyLock;
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
use opentelemetry_sdk::{
    propagation::TraceContextPropagator, resource::SdkProvidedResourceDetector, Resource,
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

    #[cfg(feature = "otlp")]
    #[error(transparent)]
    OTEL(#[from] opentelemetry_sdk::error::OTelSdkError),
}

#[derive(Clone)]
pub struct TracingHandle {
    stdout_writer: IndicatifWriter<writer::Stdout>,
    stderr_writer: IndicatifWriter<writer::Stderr>,

    #[cfg(feature = "otlp")]
    meter_provider: Option<opentelemetry_sdk::metrics::SdkMeterProvider>,

    #[cfg(feature = "otlp")]
    tracer_provider: Option<opentelemetry_sdk::trace::SdkTracerProvider>,
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
        {
            if let Some(tracer_provider) = &self.tracer_provider {
                tracer_provider.force_flush()?;
            }
            if let Some(meter_provider) = &self.meter_provider {
                meter_provider.force_flush()?;
            }
        }
        Ok(())
    }

    /// This will flush all attached tracing providers and will wait until the flush is completed, then call shutdown.
    /// If no tracing providers like otlp are attached then this will be a noop.
    ///
    /// This should only be called on a regular shutdown.
    pub async fn shutdown(&self) -> Result<(), Error> {
        self.flush().await?;
        #[cfg(feature = "otlp")]
        {
            if let Some(tracer_provider) = &self.tracer_provider {
                tracer_provider.shutdown()?;
            }
            if let Some(meter_provider) = &self.meter_provider {
                meter_provider.shutdown()?;
            }
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
        let mut g_tracer_provider = None;
        #[cfg(feature = "otlp")]
        let mut g_meter_provider = None;

        // Setup otlp if a service_name is configured
        #[cfg(feature = "otlp")]
        let layered = layered.and_then({
            if let Some(service_name) = self.service_name.map(String::from) {
                use opentelemetry::trace::TracerProvider;

                // register a text map propagator for trace propagation
                opentelemetry::global::set_text_map_propagator(TraceContextPropagator::new());

                let tracer_provider = gen_tracer_provider(service_name.clone())
                    .expect("Unable to configure trace provider");

                let meter_provider =
                    gen_meter_provider(service_name).expect("Unable to configure meter provider");

                // Register the returned meter provider as the global one.
                // FUTUREWORK: store in the struct and provide getter too?
                opentelemetry::global::set_meter_provider(meter_provider.clone());

                g_tracer_provider = Some(tracer_provider.clone());
                g_meter_provider = Some(meter_provider.clone());

                // Create a tracing layer with the configured tracer
                Some(tracing_opentelemetry::layer().with_tracer(tracer_provider.tracer("tvix")))
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
            stdout_writer,
            stderr_writer,

            #[cfg(feature = "otlp")]
            meter_provider: g_meter_provider,
            #[cfg(feature = "otlp")]
            tracer_provider: g_tracer_provider,
        })
    }
}

#[cfg(feature = "otlp")]
fn gen_resources(service_name: String) -> Resource {
    // use SdkProvidedResourceDetector.detect to detect resources,
    // but replace the default service name with our default.
    // https://github.com/open-telemetry/opentelemetry-rust/issues/1298
    //
    Resource::builder()
        .with_service_name(service_name)
        .with_detector(Box::new(SdkProvidedResourceDetector))
        .build()
}

/// Returns an OTLP tracer, and the TX part of a channel, which can be used
/// to request flushes (and signal back the completion of the flush).
#[cfg(feature = "otlp")]
fn gen_tracer_provider(
    service_name: String,
) -> Result<opentelemetry_sdk::trace::SdkTracerProvider, opentelemetry::trace::TraceError> {
    use opentelemetry_otlp::{ExportConfig, SpanExporter, WithExportConfig};

    let exporter = SpanExporter::builder()
        .with_tonic()
        .with_export_config(ExportConfig::default())
        .build()?;

    let tracer_provider = opentelemetry_sdk::trace::SdkTracerProvider::builder()
        .with_batch_exporter(exporter)
        .with_resource(gen_resources(service_name))
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

// Metric export interval should be less than or equal to 15s
// if the metrics may be converted to Prometheus metrics.
// Prometheus' query engine and compatible implementations
// require ~4 data points / interval for range queries,
// so queries ranging over 1m requre <= 15s scrape intervals.
// OTEL SDKS also respect the env var `OTEL_METRIC_EXPORT_INTERVAL` (no underscore prefix).
const _OTEL_METRIC_EXPORT_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);

#[cfg(feature = "otlp")]
fn gen_meter_provider(
    service_name: String,
) -> Result<opentelemetry_sdk::metrics::SdkMeterProvider, opentelemetry_sdk::metrics::MetricError> {
    use std::time::Duration;

    use opentelemetry_otlp::WithExportConfig;
    use opentelemetry_sdk::metrics::{PeriodicReader, SdkMeterProvider};
    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_tonic()
        .with_timeout(Duration::from_secs(10))
        .build()?;

    let reader = PeriodicReader::builder(exporter)
        .with_interval(_OTEL_METRIC_EXPORT_INTERVAL)
        .build();

    Ok(SdkMeterProvider::builder()
        .with_reader(reader)
        .with_resource(gen_resources(service_name))
        .build())
}
