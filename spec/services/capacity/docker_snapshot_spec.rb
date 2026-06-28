# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::DockerSnapshot do
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
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

    it "returns a conservative degraded snapshot when the first Docker read fails" do
      allow(backend).to receive(:system_info).and_raise(Docker::Error::DockerError.new("down"))

      snapshot = described_class.call(backend: backend, now: now, cache: cache)

      expect(snapshot).to be_degraded
      expect(snapshot.confidence).to eq(0.0)
      expect(snapshot.available_memory_bytes).to eq(0)
      expect(snapshot.degraded_reasons).to eq([ "docker_unavailable" ])
    end
  end

  def load_fixture(name)
    JSON.parse(file_fixture("capacity/docker_snapshot/#{name}").read)
  end
end
