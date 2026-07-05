# frozen_string_literal: true

module Paid
  module TemporalObservability
    PROMETHEUS_EXPORTER = "prometheus"
    DEFAULT_PROMETHEUS_BIND_ADDRESS = "0.0.0.0:9464"
    DEFAULT_SERVICE_NAME = "paid-temporal-worker"
    DEFAULT_METRIC_PREFIX = "temporal_"
    COUNTERS_TOTAL_SUFFIX = true
    UNIT_SUFFIX = true
    DURATIONS_AS_SECONDS = true

    module_function

    def worker_runtime(env = ENV)
      @worker_runtime ||= Temporalio::Runtime.new(
        telemetry: Temporalio::Runtime::TelemetryOptions.new(
          metrics: prometheus_metrics_options(env)
        )
      )
    end

    # Clears the memoized env-derived caches (worker runtime and OTLP tracer
    # configuration). Call from `Paid.reset_temporal_client!` (under the worker
    # mutex) so that a configuration change to TEMPORAL_PROMETHEUS_BIND_ADDRESS,
    # TEMPORAL_METRICS_EXPORTER, or the OTLP endpoint is honored on the next
    # worker client connection instead of reusing the first captured values.
    def reset!
      remove_instance_variable(:@worker_runtime) if defined?(@worker_runtime)
      remove_instance_variable(:@otlp_configured_endpoint) if defined?(@otlp_configured_endpoint)
    end

    def client_interceptors(env = ENV)
      tracer = temporal_tracer(env)
      return [] unless tracer

      [ Temporalio::Contrib::OpenTelemetry::TracingInterceptor.new(tracer) ]
    end

    def prometheus_metrics_options(env = ENV)
      return unless metrics_exporter(env) == PROMETHEUS_EXPORTER

      Temporalio::Runtime::MetricsOptions.new(
        prometheus: Temporalio::Runtime::PrometheusMetricsOptions.new(
          bind_address: env.fetch("TEMPORAL_PROMETHEUS_BIND_ADDRESS", DEFAULT_PROMETHEUS_BIND_ADDRESS),
          counters_total_suffix: COUNTERS_TOTAL_SUFFIX,
          unit_suffix: UNIT_SUFFIX,
          durations_as_seconds: DURATIONS_AS_SECONDS
        ),
        attach_service_name: true,
        global_tags: {
          "service_name" => env.fetch("TEMPORAL_METRICS_SERVICE_NAME", DEFAULT_SERVICE_NAME)
        },
        metric_prefix: env.fetch("TEMPORAL_METRIC_PREFIX", DEFAULT_METRIC_PREFIX)
      )
    end

    def metrics_exporter(env = ENV)
      env.fetch("TEMPORAL_METRICS_EXPORTER", PROMETHEUS_EXPORTER)
    end

    def temporal_tracer(env = ENV)
      require "opentelemetry"
      require "opentelemetry/sdk"

      configure_otlp_tracing!(env)
      OpenTelemetry.tracer_provider.tracer("paid.temporal", "1.0")
    rescue LoadError
      nil
    end

    def configure_otlp_tracing!(env = ENV)
      endpoint = otlp_endpoint(env)
      return unless endpoint

      @otel_mutex ||= Mutex.new
      @otel_mutex.synchronize do
        return if defined?(@otlp_configured_endpoint) && @otlp_configured_endpoint == endpoint

        require "opentelemetry/exporter/otlp"

        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: endpoint
        )
        tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
        tracer_provider.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
        )
        OpenTelemetry.tracer_provider = tracer_provider
        @otlp_configured_endpoint = endpoint
      end
    end

    def otlp_endpoint(env = ENV)
      env["TEMPORAL_OTEL_EXPORTER_ENDPOINT"].presence ||
        env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"].presence ||
        env["OTEL_EXPORTER_OTLP_ENDPOINT"].presence
    end
  end
end
