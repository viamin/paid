# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Operations::AutoCapacityObserver do
  let(:account) { create(:account) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:backend) do
    instance_double(
      Containers::Backends::LocalDocker,
      remote?: false,
      identifier: "local"
    )
  end

  before do
    allow(Docker).to receive(:info).and_return(
      {
        "MemTotal" => 12.gigabytes,
        "NCPU" => 8
      }
    )
  end

  it "summarizes docker usage into paid, agent, service, and other buckets" do
    create_recent_run_profile!
    allow(backend).to receive(:list_containers).with(all: false).and_return(sampled_containers)

    payload = described_class.call(account: account, manual_limit: 5, backend: backend, cache: cache)

    expect_capacity_snapshot(payload)
  end

  it "reports a degraded preview when docker metrics cannot be collected" do
    allow(Docker).to receive(:info).and_raise(StandardError, "docker unavailable")

    payload = described_class.call(
      account: account,
      manual_limit: 3,
      backend: backend,
      cache: cache
    )

    expect(payload[:status]).to eq(:degraded)
    expect(payload[:effective_recommended_concurrency]).to be_nil
    expect(payload[:warnings].first).to include("Docker metrics could not be collected")
    expect(payload[:manual_mode_summary]).to include("3 concurrent runs")
  end

  it "suppresses recommendations when a container stats call fails" do
    create_recent_run_profile!
    healthy_container = docker_container(labels: { "paid.agent_run_id" => "123" }, memory_bytes: 1.gigabyte, cpu_percent: 55.0)
    failing_container = failing_docker_container(
      labels: { "com.docker.compose.service" => "web" },
      error_message: "stats unavailable"
    )

    allow(backend).to receive(:list_containers).with(all: false).and_return([ healthy_container, failing_container ])

    payload = described_class.call(account: account, manual_limit: 5, backend: backend, cache: cache)

    expect_degraded_snapshot_payload(payload, warning: "stats unavailable")
    expect(payload.dig(:usage, :agent, :memory_bytes)).to eq(1.gigabyte)
  end

  it "returns a degraded payload for swarm backends even though swarm reports remote? == false" do
    swarm_backend = instance_double(
      Containers::Backends::Swarm,
      remote?: false,
      identifier: "swarm"
    )

    payload = described_class.call(account: account, manual_limit: 5, backend: swarm_backend, cache: cache)

    expect(payload[:status]).to eq(:degraded)
    expect(payload[:effective_recommended_concurrency]).to be_nil
    expect(payload[:warnings].first).to include("local Docker backends")
    expect(payload[:warnings].first).to include("swarm")
  end

  it "reads labels from the top-level Labels key when present" do
    create_recent_run_profile!
    summary_container = instance_double(
      Docker::Container,
      info: { "Labels" => { "paid.agent_run_id" => "123" } }
    )
    stats = docker_stats(memory_bytes: 1.gigabyte, cpu_percent: 55.0)
    allow(backend).to receive(:container_stats).with(summary_container, stream: false).and_return(stats)
    allow(backend).to receive(:list_containers).with(all: false).and_return([ summary_container ])

    payload = described_class.call(account: account, manual_limit: 5, backend: backend, cache: cache)

    expect(payload[:running_agent_count]).to eq(1)
    expect(payload.dig(:usage, :agent, :memory_bytes)).to eq(1.gigabyte)
  end

  it "falls back to Config.Labels when top-level Labels is absent (swarm-style payloads)" do
    create_recent_run_profile!
    swarm_style_container = instance_double(
      Docker::Container,
      info: { "Config" => { "Labels" => { "paid.agent_run_id" => "456" } } }
    )
    stats = docker_stats(memory_bytes: 1.gigabyte, cpu_percent: 55.0)
    allow(backend).to receive(:container_stats).with(swarm_style_container, stream: false).and_return(stats)
    allow(backend).to receive(:list_containers).with(all: false).and_return([ swarm_style_container ])

    payload = described_class.call(account: account, manual_limit: 5, backend: backend, cache: cache)

    expect(payload[:running_agent_count]).to eq(1)
    expect(payload.dig(:usage, :agent, :memory_bytes)).to eq(1.gigabyte)
  end

  def docker_container(labels:, memory_bytes:, cpu_percent:)
    info = { "Config" => { "Labels" => labels } }
    stats = docker_stats(memory_bytes:, cpu_percent:)

    instance_double(
      Docker::Container,
      info: info,
      stats: stats
    ).tap do |container|
      allow(backend).to receive(:container_stats).with(container, stream: false).and_return(stats)
    end
  end

  def failing_docker_container(labels:, error_message:)
    info = { "Config" => { "Labels" => labels } }

    instance_double(Docker::Container, info: info).tap do |container|
      allow(backend).to receive(:container_stats).with(container, stream: false)
        .and_raise(StandardError, error_message)
    end
  end

  def docker_stats(memory_bytes:, cpu_percent:)
    {
      "cpu_stats" => {
        "cpu_usage" => { "total_usage" => cpu_percent * 100 },
        "system_cpu_usage" => 1000,
        "online_cpus" => 1
      },
      "precpu_stats" => {
        "cpu_usage" => { "total_usage" => 0 },
        "system_cpu_usage" => 100
      },
      "memory_stats" => {
        "usage" => memory_bytes,
        "limit" => 12.gigabytes
      },
      "pids_stats" => {
        "current" => 12
      }
    }
  end

  def create_recent_run_profile!
    create(
      :agent_run,
      :completed,
      project: create(:project, account: account),
      peak_memory_bytes: 2.gigabytes
    )
  end

  def sampled_containers
    [
      docker_container(
        labels: { "com.docker.compose.service" => "web" },
        memory_bytes: 2.gigabytes,
        cpu_percent: 10.0
      ),
      docker_container(
        labels: { "paid.agent_run_id" => "123" },
        memory_bytes: 1.gigabyte,
        cpu_percent: 55.0
      ),
      docker_container(
        labels: { "paid.service_container" => "true" },
        memory_bytes: 1.gigabyte,
        cpu_percent: 15.0
      ),
      docker_container(
        labels: {},
        memory_bytes: 3.gigabytes,
        cpu_percent: 25.0
      )
    ]
  end

  def expect_degraded_snapshot_payload(payload, warning:)
    expect(payload[:status]).to eq(:degraded)
    expect(payload[:effective_recommended_concurrency]).to be_nil
    expect(payload[:warnings]).to contain_exactly(
      "Some Docker metrics were unavailable while building the auto-capacity preview: #{warning}"
    )
    expect(payload[:auto_mode_summary]).to eq(
      "Auto preview cannot make a trustworthy recommendation until Docker metrics recover."
    )
    expect(payload[:comparison_summary]).to eq(
      "Keep using manual mode until the Docker inspection path is healthy again."
    )
  end

  def expect_capacity_snapshot(payload)
    expect(payload[:status]).to eq(:healthy)
    expect(payload[:docker_cpu_count]).to eq(8)
    expect(payload[:docker_memory_bytes]).to eq(12.gigabytes)
    expect(payload[:running_agent_count]).to eq(1)
    expect(payload[:effective_recommended_concurrency]).to eq(2)
    expect(payload.dig(:usage, :paid, :memory_bytes)).to eq(2.gigabytes)
    expect(payload.dig(:usage, :agent, :memory_bytes)).to eq(1.gigabyte)
    expect(payload.dig(:usage, :service, :memory_bytes)).to eq(1.gigabyte)
    expect(payload.dig(:usage, :other, :memory_bytes)).to eq(3.gigabytes)
    expect(payload[:comparison_summary]).to eq("Auto preview is more conservative than the current manual limit.")
  end
end
