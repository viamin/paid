# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::DockerSnapshot do
  let(:backend) { double("backend", identifier: "local") } # rubocop:disable RSpec/VerifiedDoubles
  let(:agent_run_container) { container("agent-run", "paid.agent_run_id" => "123") }
  let(:pool_container) do
    container(
      "pool",
      "paid.container_pool" => "true",
      "paid.container_pool_entry_id" => "9"
    )
  end
  let(:mcp_sidecar_container) { container("mcp-sidecar", "paid.mcp_sidecar" => "true") }
  let(:managed_container) do
    container(
      "managed",
      "paid.managed" => "true",
      "paid.resource" => "analysis_container"
    )
  end
  let(:service_container) { container("service", "paid.service_container_id" => "77") }
  let(:paid_web_container) do
    container(
      "paid-web",
      "com.docker.compose.project" => "paid",
      "com.docker.compose.service" => "web"
    )
  end
  let(:foreign_compose_container) do
    container(
      "foreign-compose",
      "com.docker.compose.project" => "other-app",
      "com.docker.compose.service" => "db"
    )
  end
  let(:plain_unrelated_container) { container("unrelated") }
  let(:running_containers) do
    [
      agent_run_container,
      pool_container,
      mcp_sidecar_container,
      managed_container,
      service_container,
      paid_web_container,
      foreign_compose_container,
      plain_unrelated_container
    ]
  end

  around do |example|
    Rails.cache.clear
    example.run
    Rails.cache.clear
  end

  before do
    allow(Containers).to receive(:backend).and_return(backend)
    allow(backend).to receive(:list_containers).with(all: true).and_return(running_containers)
    allow(backend).to receive(:container_stats) do |container, stream:|
      raise "expected non-streaming stats" unless stream == false

      { memory_bytes: memory_by_container_id.fetch(container.id) }
    end
    allow(Containers::DockerStatsParser).to receive(:parse_stats) { |raw| raw }
    allow(Docker).to receive(:info).and_return("MemTotal" => 20.gigabytes)
  end

  describe "#fetch" do
    it "classifies Paid agent-related containers separately from control-plane and foreign compose containers" do
      snapshot = described_class.new.fetch

      expect(snapshot[:agent_memory_bytes]).to eq(7.gigabytes)
      expect(snapshot[:service_container_memory_bytes]).to eq(1.gigabyte)
      expect(snapshot[:paid_control_plane_memory_bytes]).to eq(2.gigabytes)
      expect(snapshot[:unrelated_container_memory_bytes]).to eq(7.gigabytes)
      expect(snapshot[:reserved_non_agent_bytes]).to eq(10.gigabytes)
      expect(snapshot[:spike_margin_bytes]).to eq((3.gigabytes * 0.15).to_i)
      expect(snapshot[:effective_agent_budget_bytes]).to eq(20.gigabytes - 10.gigabytes - 7.gigabytes - ((3.gigabytes * 0.15).to_i))
    end
  end

  private

  def container(id, labels = {})
    double( # rubocop:disable RSpec/VerifiedDoubles
      "container-#{id}",
      id: id,
      info: {
        "State" => { "Running" => true },
        "Config" => { "Labels" => labels }
      }
    )
  end

  def memory_by_container_id
    {
      "agent-run" => 1.gigabyte,
      "pool" => 2.gigabytes,
      "mcp-sidecar" => 1.gigabyte,
      "managed" => 3.gigabytes,
      "service" => 1.gigabyte,
      "paid-web" => 2.gigabytes,
      "foreign-compose" => 4.gigabytes,
      "unrelated" => 3.gigabytes
    }
  end
end
