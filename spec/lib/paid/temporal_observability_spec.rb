# frozen_string_literal: true

require "spec_helper"
require "temporalio/runtime"
require_relative "../../../lib/paid/temporal_observability"

RSpec.describe Paid::TemporalObservability do
  describe ".prometheus_metrics_options" do
    it "builds Prometheus runtime telemetry with seconds-based duration histograms" do
      options = described_class.prometheus_metrics_options(
        "TEMPORAL_PROMETHEUS_BIND_ADDRESS" => "127.0.0.1:9464"
      )

      expect(options).to be_a(Temporalio::Runtime::MetricsOptions)
      expect(options.prometheus.bind_address).to eq("127.0.0.1:9464")
      expect(options.prometheus.counters_total_suffix).to be(true)
      expect(options.prometheus.unit_suffix).to be(true)
      expect(options.prometheus.durations_as_seconds).to be(true)
      expect(options.metric_prefix).to eq("temporal_")
      expect(options.global_tags).to include("service_name" => "paid-temporal-worker")
    end
  end

  describe ".otlp_endpoint" do
    it "prefers the Temporal-specific OTLP endpoint override" do
      env = {
        "TEMPORAL_OTEL_EXPORTER_ENDPOINT" => "http://tempo:4318/v1/traces",
        "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://otel:4318"
      }

      expect(described_class.otlp_endpoint(env)).to eq("http://tempo:4318/v1/traces")
    end
  end

  describe ".reset!" do
    after { described_class.reset! }

    it "clears the memoized worker runtime cache" do
      described_class.instance_variable_set(:@worker_runtime, :cached_runtime)

      described_class.reset!

      expect(described_class.instance_variable_defined?(:@worker_runtime)).to be(false)
    end

    it "clears the memoized OTLP endpoint cache" do
      described_class.instance_variable_set(:@otlp_configured_endpoint, "http://otel:4318")

      described_class.reset!

      expect(described_class.instance_variable_defined?(:@otlp_configured_endpoint)).to be(false)
    end

    it "is a no-op when nothing is memoized" do
      expect { described_class.reset! }.not_to raise_error
    end
  end
end
