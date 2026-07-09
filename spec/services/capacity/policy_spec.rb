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
      expect(decision.auto_allowed_reasons).to eq([ "deployment_gate" ])
    end

    it "returns MANUAL for a swarm backend, gating auto off by default" do
      decision = described_class.call(snapshot: swarm_snapshot, now: now)

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.auto_allowed).to be(false)
      expect(decision.blocked_reasons.map(&:code)).to include("auto_mode_disabled_for_deployment")
      expect(decision.auto_allowed_reasons).to eq([ "deployment_gate" ])
    end

    it "reports the deployment gate (not metrics_missing) when auto is blocked for the deployment" do
      # linux_docker is a default-AUTO, non-CI environment. When the
      # backend is remote/swarm the deployment gate blocks auto via the
      # auto_mode_disabled_for_deployment reason — the policy must report
      # "deployment_gate" rather than falling through to "metrics_missing",
      # which is reserved for measurable-but-unreliable local snapshots.
      decision = described_class.call(
        snapshot: remote_snapshot,
        environment: "linux_docker",
        now: now
      )

      expect(decision.auto_allowed).to be(false)
      expect(decision.auto_allowed_reasons).to eq([ "deployment_gate" ])
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
      # A degraded snapshot defensively reports available_memory_bytes: 0
      # (a "we don't know" signal), which must NOT be tagged as
      # docker_exhausted — that reason is reserved for a genuinely full,
      # measurement-healthy Docker host.
      expect(decision.degraded_reasons).not_to include("docker_exhausted")
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
      expect(decision.mode).to eq(Capacity::Policy::AUTO)
    end

    it "knows orbstack defaults" do
      decision = described_class.call(environment: "orbstack", snapshot: healthy_local_snapshot, now: now)

      expect(decision.environment).to eq("orbstack")
      expect(decision.effective_max_concurrent).to eq(8)
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

  describe "#capacity_blocked?" do
    it "is true when a healthy local snapshot reports no available memory" do
      exhausted = healthy_local_snapshot(overrides: { available_memory_bytes: 0 })

      decision = described_class.call(snapshot: exhausted, now: now)

      expect(decision.blocked_reasons.map(&:code)).to include("docker_memory_exhausted")
      expect(decision.capacity_blocked?).to be(true)
    end

    it "is false when there is available memory headroom" do
      decision = described_class.call(snapshot: healthy_local_snapshot, now: now)

      expect(decision.capacity_blocked?).to be(false)
    end

    it "is false for deployment-gating reasons that fall back to manual limits" do
      # Remote/CI backends disable auto mode but must keep dispatching under
      # manual limits — they are not hard capacity blocks.
      decision = described_class.call(snapshot: remote_snapshot, now: now)

      expect(decision.blocked_reasons.map(&:code)).to include("auto_mode_disabled_for_deployment")
      expect(decision.capacity_blocked?).to be(false)
    end

    it "is false for a degraded/unmeasured snapshot even when memory is zeroed" do
      # A degraded snapshot defensively reports available_memory_bytes: 0 but
      # cannot be trusted to mean "Docker is full" — it must fall back to
      # manual limits rather than halting dispatch.
      decision = described_class.call(snapshot: degraded_snapshot, now: now)

      expect(decision.blocked_reasons.map(&:code)).to include("docker_low_confidence")
      expect(decision.capacity_blocked?).to be(false)
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
      decision = described_class.call(snapshot: local_snapshot_with_other_docker_memory, now: now)

      expect(decision.mode).to eq(Capacity::Policy::MANUAL)
      expect(decision.blocked_reasons.map(&:code)).to include("unrelated_workload")
    end

    it "does not flag unrelated_workload when the other_docker bucket reports zero memory" do
      # The shared-host check fires on the observed +other_docker+ usage
      # bucket, not on backend classification. A local host running
      # only Paid containers (other_docker memory == 0) must stay in
      # auto mode even though it is technically a "shared" endpoint.
      empty_buckets = Capacity::DockerSnapshot::EMPTY_BUCKETS
      local_snapshot = healthy_local_snapshot(
        overrides: {
          usage_buckets: empty_buckets,
          available_memory_bytes: 12_000_000_000
        }
      )

      decision = described_class.call(snapshot: local_snapshot, now: now)

      expect(decision.blocked_reasons.map(&:code)).not_to include("unrelated_workload")
      expect(decision.mode).to eq(Capacity::Policy::AUTO)
    end
  end

  def local_snapshot_with_other_docker_memory
    # A local Docker host can run non-Paid containers alongside the
    # Paid stack. The +other_docker+ usage bucket tracks that memory;
    # when it is non-zero auto mode must back off because memory-based
    # admission cannot account for memory we do not control. Note: the
    # snapshot's +backend_kind+ stays +local+ — the unrelated-workload
    # signal is the observed +other_docker+ usage, not the backend's
    # shared classification (see DockerSnapshot::classify_backend_shared).
    healthy_local_snapshot(
      overrides: {
        usage_buckets: Capacity::DockerSnapshot::EMPTY_BUCKETS.merge(
          other_docker: Capacity::DockerSnapshot::Bucket.new(
            container_count: 3,
            memory_bytes: 2_000_000_000,
            cpu_percent: 0.0
          )
        ),
        available_memory_bytes: 6_000_000_000
      }
    )
  end
end
