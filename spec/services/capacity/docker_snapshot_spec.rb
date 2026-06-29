# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::DockerSnapshot do
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local", all_host_identifiers: [ "local" ]) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.zone.parse("2026-06-28 12:00:00 UTC") }
  let(:project) { create(:project) }
  let(:agent_run) do
    create(
      :agent_run,
      :running,
      project: project,
      id: 2731,
      container_id: "agent-run-2731",
      container_host: "local",
      mcp_sidecar_container_ids: [ "mcp-sidecar-2731" ]
    )
  end
  let(:service_container) do
    create(
      :service_container,
      account: project.account,
      id: 88,
      status: "running",
      docker_container_id: "service-container-88"
    )
  end
  let(:chat_session) do
    create(
      :chat_session,
      account: project.account,
      status: "active",
      container_id: "chat-session-31"
    )
  end
  let(:system_info) { load_fixture("system_info.json") }
  let(:container_rows) { load_fixture("containers.json") }
  let(:containers) do
    container_rows.map do |row|
      instance_double(
        Docker::Container,
        id: row.fetch("id"),
        info: row.fetch("info")
      ).tap do |container|
        allow(backend).to receive(:container_stats).with(container, stream: false).and_return(row.fetch("stats"))
      end
    end
  end

  before do
    agent_run
    service_container
    chat_session

    allow(backend).to receive_messages(
      capacity_snapshot_list_container_options: {},
      system_info: system_info,
      list_containers: containers
    )
  end

  describe ".call" do
    it "returns Docker capacity, aggregate usage buckets, timestamp, and confidence" do
      snapshot = described_class.call(backend: backend, now: now, cache: cache)

      expect(snapshot.docker_cpu_count).to eq(8)
      expect(snapshot.docker_memory_bytes).to eq(16_000)
      expect(snapshot.snapshot_at).to eq(now)
      expect(snapshot.confidence).to eq(1.0)
      expect(snapshot).not_to be_degraded
      expect(snapshot.agent_container_count).to eq(2)
      expect(snapshot.available_memory_bytes).to eq(7_400)
    end

    it "classifies containers from fixtures into paid buckets and aggregates unrelated usage" do
      snapshot = described_class.call(backend: backend, now: now, cache: cache)

      expect(snapshot.usage_buckets).to include(
        paid_control_plane: have_attributes(container_count: 3, memory_bytes: 3_400, cpu_percent: 16.0),
        paid_agents: have_attributes(container_count: 2, memory_bytes: 3_500, cpu_percent: 34.0),
        paid_service_containers: have_attributes(container_count: 1, memory_bytes: 1_200, cpu_percent: 8.0),
        other_docker: have_attributes(container_count: 1, memory_bytes: 500, cpu_percent: 2.0)
      )
    end

    it "does not expose unrelated container names, images, labels, or mounts in the snapshot payload" do
      snapshot = described_class.call(backend: backend, now: now, cache: cache)
      payload = snapshot.to_h.deep_stringify_keys.to_json

      expect(payload).not_to include("postgres:16")
      expect(payload).not_to include("unrelated-ci-db")
      expect(payload).not_to include("com.docker.compose.project")
      expect(payload).not_to include("/var/lib/postgresql/data")
    end

    it "falls back to DB-backed classification when labels are absent" do
      allow(containers.first).to receive(:info).and_return(
        container_rows.first.fetch("info").merge("Labels" => {})
      )

      snapshot = described_class.call(backend: backend, now: now, cache: cache, force_refresh: true)

      expect(snapshot.bucket(:paid_agents).container_count).to eq(2)
      expect(snapshot.bucket(:paid_agents).memory_bytes).to eq(3_500)
    end

    it "degrades safely when Docker becomes unavailable after a cached snapshot exists" do
      described_class.call(backend: backend, now: now, cache: cache)
      allow(backend).to receive(:system_info).and_raise(Timeout::Error)

      snapshot = described_class.call(
        backend: backend,
        now: now + described_class::CACHE_TTL + 1.second,
        cache: cache
      )

      expect(snapshot).to be_degraded
      expect(snapshot.available_memory_bytes).to eq(0)
      expect(snapshot.confidence).to eq(0.1)
      expect(snapshot.degraded_reasons).to include("stale_cache", "docker_timeout")
    end

    it "preserves a healthy cached snapshot when deserializing explicit false values" do
      snapshot = described_class.call(backend: backend, now: now, cache: cache)
      cached_snapshot = described_class.deserialize(cache.read(described_class.cache_key(backend.identifier)))

      expect(snapshot).not_to be_degraded
      expect(cached_snapshot).not_to be_degraded
      expect(cached_snapshot.degraded).to be(false)
    end

    it "returns a conservative degraded snapshot when the first Docker read fails" do
      allow(backend).to receive(:system_info).and_raise(Docker::Error::DockerError.new("down"))

      snapshot = described_class.call(backend: backend, now: now, cache: cache)

      expect(snapshot).to be_degraded
      expect(snapshot.confidence).to eq(0.0)
      expect(snapshot.available_memory_bytes).to eq(0)
      expect(snapshot.degraded_reasons).to eq([ "docker_unavailable" ])
    end

    it "uses backend host identifiers for DB-backed swarm classification when labels are absent" do
      agent_run.update!(container_host: "worker-1")
      allow(backend).to receive_messages(
        identifier: "swarm",
        all_host_identifiers: [ "worker-1", "swarm" ],
        capacity_snapshot_list_container_options: { include_node_containers: true }
      )
      allow(containers.first).to receive(:info).and_return(
        container_rows.first.fetch("info").merge("Labels" => {})
      )

      snapshot = described_class.call(backend: backend, now: now, cache: cache, force_refresh: true)

      expect(snapshot.bucket(:paid_agents).container_count).to eq(2)
      expect(snapshot.bucket(:other_docker).container_count).to eq(1)
    end

    it "accounts for standalone swarm-node containers in other_docker usage" do
      standalone = build_container(id: "standalone-db", labels: { "com.example.role" => "db" })
      allow(backend).to receive_messages(
        identifier: "swarm",
        all_host_identifiers: [ "worker-1", "swarm" ],
        capacity_snapshot_list_container_options: { include_node_containers: true },
        list_containers: containers + [ standalone ]
      )
      allow(backend).to receive(:container_stats).with(standalone, stream: false).and_return(stats_payload(memory_bytes: 700, cpu_percent: 30.0))

      snapshot = described_class.call(backend: backend, now: now, cache: cache, force_refresh: true)

      expect(snapshot.bucket(:other_docker)).to have_attributes(container_count: 2, memory_bytes: 1_200, cpu_percent: 32.0)
      expect(snapshot.available_memory_bytes).to eq(6_700)
    end

    it "bypasses tenant RLS when building daemon-wide references" do
      other_account = create(:account)

      allow(TenantContext).to receive(:with_system_access).and_call_original
      allow(containers.first).to receive(:info).and_return(
        container_rows.first.fetch("info").merge("Labels" => {})
      )
      allow(containers.second).to receive(:info).and_return(
        container_rows.second.fetch("info").merge("Labels" => {})
      )
      allow(containers[2]).to receive(:info).and_return(
        container_rows[2].fetch("info").merge("Labels" => {})
      )

      snapshot = TenantContext.with(other_account) do
        described_class.call(backend: backend, now: now, cache: cache, force_refresh: true)
      end

      expect(TenantContext).to have_received(:with_system_access).at_least(:once)
      expect(snapshot.bucket(:paid_agents)).to have_attributes(container_count: 2, memory_bytes: 3_500)
      expect(snapshot.bucket(:paid_service_containers)).to have_attributes(container_count: 1, memory_bytes: 1_200)
      expect(snapshot.bucket(:paid_control_plane)).to have_attributes(container_count: 3, memory_bytes: 3_400)
    end

    it "cuts off container sampling once the shared deadline is exhausted" do
      monotonic_times = [
        100.0,
        100.0,
        100.2,
        100.4,
        103.1
      ]
      snapshotter = described_class.new(backend: backend, now: now, cache: cache, force_refresh: true)
      allow(snapshotter).to receive(:monotonic_now) { monotonic_times.shift || 103.1 }

      snapshot = snapshotter.call

      expect(snapshot).to be_degraded
      expect(snapshot.available_memory_bytes).to eq(0)
      expect(snapshot.degraded_reasons).to include("container_sampling_budget_exceeded")
      expect(snapshot.bucket(:paid_agents)).to have_attributes(container_count: 1, memory_bytes: 3_000, cpu_percent: 22.0)
      expect(snapshot.bucket(:other_docker)).to have_attributes(container_count: 6, memory_bytes: 0, cpu_percent: 0.0)
    end

    it "only treats compose workdirs with an exact paid basename as control plane containers" do
      stub_compose_labels(containers[3], container_rows[3], {
        "com.docker.compose.project" => "random",
        "com.docker.compose.project.working_dir" => "/srv/unpaid-tools"
      })
      stub_compose_labels(containers[4], container_rows[4], {
        "com.docker.compose.project" => "random",
        "com.docker.compose.project.working_dir" => "C:\\src\\paid",
        "com.docker.compose.service" => "postgres"
      })

      snapshot = described_class.call(backend: backend, now: now, cache: cache, force_refresh: true)

      expect(snapshot.bucket(:paid_control_plane)).to have_attributes(container_count: 2, memory_bytes: 1_600, cpu_percent: 6.0)
      expect(snapshot.bucket(:other_docker)).to have_attributes(container_count: 2, memory_bytes: 2_300, cpu_percent: 12.0)
    end
  end

  def load_fixture(name)
    JSON.parse(file_fixture("capacity/docker_snapshot/#{name}").read)
  end

  def stub_compose_labels(container, row, labels)
    info = row.fetch("info")
    allow(container).to receive(:info).and_return(
      info.merge("Labels" => info.fetch("Labels").merge(labels))
    )
  end

  def build_container(id:, labels:, state: "running")
    instance_double(
      Docker::Container,
      id: id,
      info: {
        "Id" => id,
        "Labels" => labels,
        "State" => state
      }
    )
  end

  def stats_payload(memory_bytes:, cpu_percent:)
    system_cpu_delta = 10_000
    total_cpu_delta = ((cpu_percent / 100.0) * system_cpu_delta).to_i

    {
      "memory_stats" => { "usage" => memory_bytes },
      "cpu_stats" => {
        "cpu_usage" => { "total_usage" => total_cpu_delta },
        "system_cpu_usage" => system_cpu_delta,
        "online_cpus" => 1
      },
      "precpu_stats" => {
        "cpu_usage" => { "total_usage" => 0 },
        "system_cpu_usage" => 0
      }
    }
  end
end
