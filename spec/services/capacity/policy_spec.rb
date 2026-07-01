# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::Policy do
  let(:now) { Time.zone.parse("2026-06-30 12:00:00 UTC") }

  def healthy_local_snapshot(overrides: {})
    Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "local",
      backend_kind: "local",
      backend_shared: false,
      docker_cpu_count: 8,
      docker_memory_bytes: 16_000_000_000,
      usage_buckets: {},
      available_memory_bytes: 8_000_000_000,
      agent_container_count: 1,
      snapshot_at: now,
      confidence: 1.0,
      degraded: false,
      degraded_reasons: [],
      **overrides
    )
  end

  def remote_snapshot
    Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "prod-broker",
      backend_kind: "remote",
      backend_shared: true,
      docker_cpu_count: 32,
      docker_memory_bytes: 64_000_000_000,
      usage_buckets: {},
      available_memory_bytes: 32_000_000_000,
      agent_container_count: 0,
      snapshot_at: now,
      confidence: 1.0,
      degraded: false,
      degraded_reasons: []
    )
  end

  def swarm_snapshot
    Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "swarm",
      backend_kind: "swarm",
      backend_shared: false,
      docker_cpu_count: 16,
      docker_memory_bytes: 32_000_000_000,
      usage_buckets: {},
      available_memory_bytes: 12_000_000_000,
      agent_container_count: 4,
      snapshot_at: now,
      confidence: 1.0,
      degraded: false,
      degraded_reasons: []
    )
  end

  def degraded_snapshot
    Capacity::DockerSnapshot::Snapshot.new(
      backend_identifier: "local",
      backend_kind: "local",
      backend_shared: false,
      docker_cpu_count: 4,
      docker_memory_bytes: 8_000_000_000,
      usage_buckets: {},
      available_memory_bytes: 0,
      agent_container_count: 0,
      snapshot_at: now - 5.minutes,
      confidence: 0.1,
      degraded: true,
      degraded_reasons: [ "docker_timeout", "container_sampling_budget_exceeded" ]
    )
  end

  describe "mode selection" do
    it "returns AUTO with sensible defaults for a healthy local snapshot" do
      decision = described_class.call(snapshot: healthy_local_snapshot, now: now)

      expect(decision.mode).to eq(Capacity::Policy::AUTO)
      expect(decision.auto_allowed).to be(true)
      expect(decision.environment).to eq(Capacity::Policy::ENVIRONMENT_LINUX_DOCKER)
      expect(decision.admission_uses_cpu).to be(false)
      expect(decision.effective_max_concurrent).to eq(10)
    end

    it "returns MANUAL for a remote backend, gating auto off by default" do
      decision = described_class.call(snapshot: remote_snapshot, now: now)

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.auto_allowed).to be(false)
      expect(decision.blocked_reasons.map(&:code)).to include("auto_mode_disabled_for_deployment")
    end

    it "returns MANUAL for a swarm backend, gating auto off by default" do
      decision = described_class.call(snapshot: swarm_snapshot, now: now)

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.auto_allowed).to be(false)
      expect(decision.blocked_reasons.map(&:code)).to include("auto_mode_disabled_for_deployment")
    end

    it "fails closed to MANUAL when the snapshot is missing" do
      decision = described_class.call(snapshot: nil, now: now)

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.snapshot_present).to be(false)
      expect(decision.blocked_reasons.map(&:code)).to include("docker_unavailable")
    end

    it "fails closed to MANUAL when the snapshot is degraded" do
      decision = described_class.call(snapshot: degraded_snapshot, now: now)

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.degraded).to be(true)
      expect(decision.degraded_reasons).to include("docker_timeout")
      expect(decision.blocked_reasons.map(&:code)).to include("docker_low_confidence")
    end

    it "honors explicit opt-out even when auto would otherwise be allowed" do
      decision = described_class.call(snapshot: healthy_local_snapshot, now: now, explicit_opt_out: true)

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.auto_allowed).to be(false)
      expect(decision.auto_allowed_reasons).to eq([ "explicit_opt_out" ])
    end

    it "respects an explicit manual override for the deployment" do
      decision = described_class.call(snapshot: healthy_local_snapshot, now: now, explicit_mode: "manual")

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
    end

    it "ignores an explicit auto override when the deployment gate blocks auto" do
      decision = described_class.call(snapshot: remote_snapshot, now: now, explicit_mode: "auto")

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.auto_allowed).to be(false)
      expect(decision.blocked_reasons.map(&:code)).to include("auto_mode_disabled_for_deployment")
    end
  end

  describe "environment defaults" do
    it "knows docker_desktop defaults" do
      decision = described_class.call(environment: "docker_desktop", snapshot: healthy_local_snapshot, now: now)

      expect(decision.environment).to eq("docker_desktop")
      expect(decision.effective_max_concurrent).to eq(6)
      expect(decision.memory_safety_multiplier).to eq(1.25)
      expect(decision.mode).to eq(Capacity::Policy::AUTO)
    end

    it "knows orbstack defaults" do
      decision = described_class.call(environment: "orbstack", snapshot: healthy_local_snapshot, now: now)

      expect(decision.environment).to eq("orbstack")
      expect(decision.effective_max_concurrent).to eq(8)
      expect(decision.memory_safety_multiplier).to eq(1.20)
      expect(decision.mode).to eq(Capacity::Policy::AUTO)
    end

    it "knows linux_docker defaults" do
      decision = described_class.call(environment: "linux_docker", snapshot: healthy_local_snapshot, now: now)

      expect(decision.environment).to eq("linux_docker")
      expect(decision.effective_max_concurrent).to eq(10)
    end

    it "locks CI deployments to MANUAL regardless of snapshot" do
      decision = described_class.call(
        environment: "ci",
        snapshot: healthy_local_snapshot,
        now: now,
        ci: true
      )

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.effective_max_concurrent).to eq(2)
      expect(decision.cooldown_seconds).to eq(10 * 60)
      expect(decision.blocked_reasons.map(&:code)).to include("auto_mode_disabled_for_deployment")
    end

    it "treats unknown environments as unknown with conservative manual defaults" do
      decision = described_class.call(environment: "wat", snapshot: nil, now: now)

      expect(decision.environment).to eq("unknown")
      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
    end
  end

  describe "explicit opt-in" do
    it "enables AUTO for a remote backend when explicitly opted in" do
      decision = described_class.call(
        snapshot: remote_snapshot,
        now: now,
        explicit_opt_in: true
      )

      expect(decision.mode).to eq(Capacity::Policy::AUTO)
      expect(decision.auto_allowed).to be(true)
      expect(decision.auto_allowed_reasons).to include("explicit_opt_in")
    end

    it "enables AUTO for a swarm backend when explicitly opted in" do
      decision = described_class.call(
        snapshot: swarm_snapshot,
        now: now,
        explicit_opt_in: true
      )

      expect(decision.mode).to eq(Capacity::Policy::AUTO)
      expect(decision.auto_allowed).to be(true)
    end

    it "does not enable AUTO for CI even with explicit opt-in" do
      decision = described_class.call(
        snapshot: healthy_local_snapshot,
        environment: "linux_docker",
        now: now,
        ci: true,
        explicit_opt_in: true
      )

      # CI always forces manual mode by design — opt-in is not enough
      # to override the deployment-level safety rule.
      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.auto_allowed).to be(false)
    end

    it "still fails closed to MANUAL when the snapshot is degraded, even with opt-in" do
      decision = described_class.call(
        snapshot: degraded_snapshot,
        now: now,
        explicit_opt_in: true
      )

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.auto_allowed).to be(false)
    end
  end

  describe "cpu participation" do
    it "documents the memory-first default" do
      decision = described_class.call(snapshot: healthy_local_snapshot, now: now)

      expect(decision.admission_uses_cpu).to be(false)
    end
  end

  describe ".to_h" do
    it "returns safe, UI-friendly payload keys only" do
      decision = described_class.call(snapshot: remote_snapshot, now: now)
      payload = decision.to_h

      expect(payload.keys).to all(be_a(Symbol))
      expect(payload[:blocked_reasons]).not_to be_empty
      expect(payload[:blocked_reasons].first.keys).to all(be_a(Symbol))
      expect(payload[:blocked_reasons].first.values).to all(be_a(String))
    end

    it "serializes an empty blocked_reasons list when nothing blocks" do
      decision = described_class.call(snapshot: healthy_local_snapshot, now: now)

      expect(decision.to_h[:blocked_reasons]).to eq([])
    end
  end

  describe "unrelated Docker workloads" do
    it "marks a healthy local snapshot with memory pressure as Docker exhausted" do
      busy_snapshot = Capacity::DockerSnapshot::Snapshot.new(
        backend_identifier: "local",
        backend_kind: "local",
        backend_shared: false,
        docker_cpu_count: 8,
        docker_memory_bytes: 16_000_000_000,
        usage_buckets: {},
        available_memory_bytes: 0,
        agent_container_count: 1,
        snapshot_at: now,
        confidence: 1.0,
        degraded: false,
        degraded_reasons: []
      )

      decision = described_class.call(snapshot: busy_snapshot, now: now)

      expect(decision.blocked_reasons.map(&:code)).to include("docker_memory_exhausted")
      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
    end

    it "still falls back to MANUAL when unrelated containers consume Docker capacity" do
      # Simulate a "shared" docker host running unrelated workloads alongside
      # a local Paid stack. The backend reports itself as shared, so auto
      # mode stays off even though memory looks fine.
      shared_local_snapshot = Capacity::DockerSnapshot::Snapshot.new(
        backend_identifier: "local",
        backend_kind: "local",
        backend_shared: true,
        docker_cpu_count: 8,
        docker_memory_bytes: 16_000_000_000,
        usage_buckets: {},
        available_memory_bytes: 6_000_000_000,
        agent_container_count: 1,
        snapshot_at: now,
        confidence: 1.0,
        degraded: false,
        degraded_reasons: []
      )

      decision = described_class.call(snapshot: shared_local_snapshot, now: now)

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.blocked_reasons.map(&:code)).to include("unrelated_workload",
        "auto_mode_disabled_for_deployment")
    end
  end
end
