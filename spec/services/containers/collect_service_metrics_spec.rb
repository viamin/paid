# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::CollectServiceMetrics do
  let(:service_container) { create(:service_container, :running, docker_container_id: "container123", container_host: "elguapo") }
  let(:backend) { instance_double(Containers::Backends::Base) }

  let(:docker_stats) do
    {
      "cpu_stats" => {
        "cpu_usage" => { "total_usage" => 500_000_000 },
        "system_cpu_usage" => 10_000_000_000,
        "online_cpus" => 2
      },
      "precpu_stats" => {
        "cpu_usage" => { "total_usage" => 400_000_000 },
        "system_cpu_usage" => 9_000_000_000
      },
      "memory_stats" => {
        "usage" => 2_147_483_648,
        "limit" => 4_294_967_296
      },
      "pids_stats" => {
        "current" => 42
      }
    }
  end

  let(:mock_container) { instance_double(Docker::Container, stats: docker_stats) }

  before do
    allow(Containers).to receive(:backend_for).with("elguapo").and_return(backend)
    allow(backend).to receive(:get_container).with("container123").and_return(mock_container)
    allow(backend).to receive(:container_stats).with(mock_container, stream: false).and_return(docker_stats)
  end

  it "creates a service container metric record" do
    expect { described_class.call(service_container: service_container) }
      .to change(ServiceContainerMetric, :count).by(1)
  end

  it "updates service container summary fields" do
    described_class.call(service_container: service_container)
    service_container.reload

    expect(service_container.peak_cpu_percent).to eq(20.0)
    expect(service_container.peak_memory_bytes).to eq(2_147_483_648)
    expect(service_container.avg_cpu_percent).to eq(20.0)
    expect(service_container.avg_memory_bytes).to eq(BigDecimal("2147483648"))
    expect(service_container.container_metrics_count).to eq(1)
  end

  it "returns nil when the service container is not running" do
    service_container.update_columns(status: "stopped")
    expect(described_class.call(service_container: service_container)).to be_nil
  end

  it "handles missing containers gracefully" do
    allow(backend).to receive(:get_container).and_raise(Docker::Error::NotFoundError)
    allow(Rails.logger).to receive(:warn)

    expect(described_class.call(service_container: service_container)).to eq(:not_found)
    expect(Rails.logger).to have_received(:warn).with(
      hash_including(message: "container_manager.service_container_not_found")
    )
  end

  it "routes service metrics through the persisted container host backend" do
    described_class.call(service_container: service_container)

    expect(Containers).to have_received(:backend_for).with("elguapo")
    expect(backend).to have_received(:get_container).with("container123")
    expect(backend).to have_received(:container_stats).with(mock_container, stream: false)
  end
end
