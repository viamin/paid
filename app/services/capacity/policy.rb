# frozen_string_literal: true

module Capacity
  # Decides whether auto-capacity is allowed and what defaults apply
  # for the current deployment. Acts as the single source of truth that
  # ProcessRunQueueJob, dashboards, and tuning decisions consult before
  # applying auto-mode behavior.
  #
  # Design (RDR-043 Phase 6):
  #
  # - Auto mode is **off by default** for shared/managed/remote Docker
  #   backends. Local single-user desktop backends opt into auto mode
  #   automatically, but the deployment may explicitly opt out.
  # - Auto mode **fails closed** when Docker metrics are missing,
  #   stale, or low confidence — the policy returns manual defaults
  #   and reports the degraded reason rather than guessing.
  # - The first implementation is memory-first; CPU intentionally
  #   does not participate.
  # - Each deployment environment (Docker Desktop, OrbStack, Linux
  #   Docker, CI) carries its own per-environment defaults rather than
  #   sharing one global rule.
  class Policy
    # Capacity modes exposed by the policy.
    AUTO = "auto".freeze
    MANUAL = "manual".freeze
    MODES = [ AUTO, MANUAL ].freeze

    # Environment fingerprints detected from the Docker snapshot's
    # identification, kernel version, and CI markers. Used to choose
    # deployment-appropriate defaults.
    ENVIRONMENT_CI = "ci".freeze
    ENVIRONMENT_DOCKER_DESKTOP = "docker_desktop".freeze
    ENVIRONMENT_ORBSTACK = "orbstack".freeze
    ENVIRONMENT_LINUX_DOCKER = "linux_docker".freeze
    ENVIRONMENT_UNKNOWN = "unknown".freeze

    Environments = Struct.new(:name, :default_mode, :default_max_concurrent, keyword_init: true) do
      def to_h
        {
          name: name,
          default_mode: default_mode,
          default_max_concurrent: default_max_concurrent
        }
      end
    end

    ENVIRONMENT_DEFAULTS = {
      ENVIRONMENT_DOCKER_DESKTOP => Environments.new(
        name: ENVIRONMENT_DOCKER_DESKTOP,
        default_mode: AUTO,
        default_max_concurrent: 6
      ),
      ENVIRONMENT_ORBSTACK => Environments.new(
        name: ENVIRONMENT_ORBSTACK,
        default_mode: AUTO,
        default_max_concurrent: 8
      ),
      ENVIRONMENT_LINUX_DOCKER => Environments.new(
        name: ENVIRONMENT_LINUX_DOCKER,
        default_mode: AUTO,
        default_max_concurrent: 10
      ),
      ENVIRONMENT_CI => Environments.new(
        name: ENVIRONMENT_CI,
        # CI is by definition non-interactive; auto mode is dangerous
        # because a runaway OOM can take down the runner. Manual mode
        # is the safe default.
        default_mode: MANUAL,
        default_max_concurrent: 2
      ),
      ENVIRONMENT_UNKNOWN => Environments.new(
        name: ENVIRONMENT_UNKNOWN,
        default_mode: MANUAL,
        default_max_concurrent: 4
      )
    }.freeze

    Decision = Struct.new(:mode, :environment, :auto_allowed, :auto_allowed_reasons,
      :blocked_reasons, :admission_uses_cpu, :degraded, :degraded_reasons,
      :effective_max_concurrent, :snapshot_present, keyword_init: true) do
      # Reason codes that signal Docker has no measurable memory headroom for
      # another agent run right now. When any are present the queue processor
      # must leave the run queued regardless of run-count headroom — RDR-043
      # prefers denying new runs over OOM-killing active ones.
      #
      # Deployment-gating reasons (`auto_mode_disabled_for_deployment`,
      # `docker_unavailable`, `docker_low_confidence`) are intentionally
      # excluded: those fall back to conservative manual limits rather than
      # halting dispatch, which is the RDR-mandated fail-safe behavior for
      # backends where auto mode is not appropriate or Docker is unmeasurable.
      CAPACITY_BLOCKING_REASONS = %w[docker_memory_exhausted docker_sampling_budget_exceeded].freeze

      def auto?
        mode == Policy::AUTO
      end

      def manual?
        mode == Policy::MANUAL
      end

      # True when Docker has no memory headroom for another run in a
      # measurable environment. This is keyed off the
      # `docker_memory_exhausted` reason (available_memory_bytes == 0 while
      # Docker reports a memory budget) rather than the raw byte count so a
      # degraded/unmeasured snapshot — which zeroes available memory
      # defensively — still falls back to manual limits instead of halting
      # dispatch.
      def capacity_blocked?
        blocked_reasons.any? { |reason| CAPACITY_BLOCKING_REASONS.include?(reason.code) }
      end

      def to_h
        {
          mode: mode,
          environment: environment,
          auto_allowed: auto_allowed,
          auto_allowed_reasons: auto_allowed_reasons,
          blocked_reasons: blocked_reasons.map(&:to_h),
          admission_uses_cpu: admission_uses_cpu,
          degraded: degraded,
          degraded_reasons: degraded_reasons,
          effective_max_concurrent: effective_max_concurrent,
          snapshot_present: snapshot_present
        }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(
      snapshot: nil,
      environment: nil,
      explicit_mode: nil,
      explicit_opt_in: false,
      explicit_opt_out: false,
      ci: nil,
      now: Time.current
    )
      @snapshot = snapshot
      @environment = environment
      @explicit_mode = explicit_mode
      @explicit_opt_in = explicit_opt_in
      @explicit_opt_out = explicit_opt_out
      @ci = ci
      @now = now
    end

    def call
      env = resolve_environment
      blocked = build_blocked_reasons(env)
      degraded_reasons = compute_degraded_reasons

      degraded = degraded_reasons.any?

      auto_allowed = compute_auto_allowed(env: env, blocked: blocked, degraded_reasons: degraded_reasons)
      mode = resolve_mode(env: env, auto_allowed: auto_allowed, blocked: blocked, degraded: degraded)

      Decision.new(
        mode: mode,
        environment: env.name,
        auto_allowed: auto_allowed,
        auto_allowed_reasons: compute_auto_allowed_reasons(env: env, blocked: blocked, auto_allowed: auto_allowed),
        blocked_reasons: blocked,
        # Phase 6 keeps admission memory-first; CPU participation is
        # deferred until memory tuning stabilizes across environments.
        admission_uses_cpu: false,
        degraded: degraded,
        degraded_reasons: degraded_reasons,
        effective_max_concurrent: effective_max_concurrent(env),
        snapshot_present: @snapshot.present?
      )
    end

    private

    attr_reader :snapshot, :environment, :explicit_mode, :explicit_opt_in, :explicit_opt_out,
      :ci, :now

    def resolve_environment
      return ENVIRONMENT_DEFAULTS.fetch(ENVIRONMENT_CI) if ci
      return ENVIRONMENT_DEFAULTS.fetch(environment.to_s) if environment && ENVIRONMENT_DEFAULTS.key?(environment.to_s)

      detected = detect_environment_from_snapshot
      ENVIRONMENT_DEFAULTS.fetch(detected)
    end

    def detect_environment_from_snapshot
      return ENVIRONMENT_UNKNOWN if snapshot.blank?

      identifier = snapshot.backend_identifier.to_s.downcase
      return ENVIRONMENT_ORBSTACK if identifier.include?("orb") || identifier.include?("orbstack")
      return ENVIRONMENT_DOCKER_DESKTOP if identifier.include?("desktop") || docker_desktop_signals?
      return ENVIRONMENT_LINUX_DOCKER if snapshot.local?

      ENVIRONMENT_UNKNOWN
    end

    # Heuristic signals that suggest Docker Desktop: presence of a
    # docker socket on macOS or the Desktop-specific `cloud` context.
    # Best-effort only; falls back to environment name match.
    def docker_desktop_signals?
      ENV["DOCKER_HOST"].to_s.include?("docker-desktop") ||
        ENV["DOCKER_DESKTOP"].present?
    end

    def build_blocked_reasons(env)
      blocked = []

      if snapshot.blank?
        blocked << BlockedReason[:docker_unavailable]
        return blocked
      end

      if snapshot.degraded?
        blocked << BlockedReason[:docker_low_confidence]
      end

      if snapshot.degraded_reasons.include?("container_sampling_budget_exceeded")
        blocked << BlockedReason[:docker_sampling_budget_exceeded]
      end

      if snapshot.available_memory_bytes.to_i.zero? && snapshot.docker_memory_bytes.to_i.positive?
        # Only assert a hard memory block when the snapshot is measurement
        # healthy. A degraded/unmeasured snapshot defensively reports
        # available_memory_bytes: 0, but that is a "we don't know" signal,
        # not a "Docker is full" signal — RDR-043 requires falling back to
        # manual limits rather than halting dispatch when metrics are
        # unreliable. Capacity::Policy::Decision#capacity_blocked? keys off
        # this reason to leave capacity-blocked runs queued.
        blocked << BlockedReason[:docker_memory_exhausted] unless snapshot.degraded?
      end

      if unrelated_workload_detected?(snapshot)
        # Docker is running non-Paid containers that are consuming
        # capacity we cannot fairly schedule against. Auto stays off
        # because memory-based admission cannot account for memory we
        # do not control.
        blocked << BlockedReason[:unrelated_workload]
      end

      if snapshot.shared? || snapshot.remote? || snapshot.swarm?
        blocked << BlockedReason[:auto_mode_disabled_for_deployment]
      end

      if env.name == ENVIRONMENT_CI
        # CI is always blocked from auto by design; this is a different
        # reason than the "no opt-in" gating.
        blocked << BlockedReason[:auto_mode_disabled_for_deployment]
      end

      blocked.uniq
    end

    def compute_degraded_reasons
      return [ "no_snapshot" ] if snapshot.blank?

      reasons = []
      reasons << "docker_low_confidence" if snapshot.confidence.to_f < 0.5
      reasons << "docker_timeout" if snapshot.degraded_reasons.include?("docker_timeout")
      reasons << "container_sampling_budget_exceeded" if snapshot.degraded_reasons.include?("container_sampling_budget_exceeded")
      # A degraded/unmeasured snapshot defensively reports
      # available_memory_bytes: 0 (see DockerSnapshot#collect_snapshot),
      # but that is a "we don't know" signal, not a "Docker is full"
      # signal — mirror the guard used in build_blocked_reasons so a
      # degraded snapshot is not spuriously tagged docker_exhausted.
      reasons << "docker_exhausted" if snapshot.available_memory_bytes.to_i.zero? && !snapshot.degraded?

      reasons
    end

    # Detects whether the local Docker host is running non-Paid
    # containers that consume a non-trivial share of the memory budget.
    # Backend-level "shared" classification (see DockerSnapshot) is
    # orthogonal: a local socket can host unrelated containers, and a
    # remote shared endpoint may run nothing but Paid — so we look at
    # the observed +other_docker+ usage bucket, not the backend kind.
    def unrelated_workload_detected?(snapshot)
      return false unless snapshot.local?

      buckets = snapshot.usage_buckets
      return false unless buckets.is_a?(Hash)

      other_bucket = buckets[:other_docker] || buckets["other_docker"]
      return false unless other_bucket

      other_bucket.memory_bytes.to_i.positive?
    end

    def compute_auto_allowed(env:, blocked:, degraded_reasons:)
      return false if explicit_opt_out == true
      # CI is always locked to MANUAL by design — no opt-in can override it.
      return false if env.name == ENVIRONMENT_CI
      # Unrelated workload is observed memory consumption, not a
      # deployment policy: even an explicit opt-in cannot make auto
      # mode safe when we cannot account for memory we do not control.
      return false if blocked.any? { |reason| reason.code == "unrelated_workload" }
      # Deployment gate: auto is off by default for shared/remote/swarm
      # backends. explicit_opt_in lets operators enable auto on those
      # deployments ("disabled by default unless explicitly opted in").
      unless explicit_opt_in
        return false if env.default_mode == MANUAL
        return false if blocked.any? { |reason| reason.code == "auto_mode_disabled_for_deployment" }
      end
      return false if degraded_reasons.any?
      return false if explicit_mode == MANUAL

      true
    end

    def compute_auto_allowed_reasons(env:, blocked:, auto_allowed:)
      return [ "explicit_opt_out" ] if explicit_opt_out == true
      return [ "explicit_opt_in" ] if auto_allowed && explicit_opt_in
      return [ "environment_default" ] if auto_allowed
      # Auto is off because the deployment gate fired (shared/remote/swarm
      # backend or CI). Report the gate rather than the catch-all
      # "metrics_missing", which is reserved for measurable-but-unreliable
      # local snapshots.
      return [ "deployment_gate" ] if blocked.any? { |reason| reason.code == "auto_mode_disabled_for_deployment" }
      return [ "deployment_gate" ] if env.default_mode == MANUAL || env.name == ENVIRONMENT_CI
      # Docker is fully measured and reporting no memory headroom. This is a
      # hard capacity condition, not a measurement gap — report it explicitly
      # rather than falling through to "metrics_missing". Checked after the
      # deployment gate so a remote/swarm backend that is also exhausted still
      # reports the more fundamental "deployment_gate" reason.
      return [ "docker_memory_exhausted" ] if blocked.any? { |reason| reason.code == "docker_memory_exhausted" }

      [ "metrics_missing" ]
    end

    def resolve_mode(env:, auto_allowed:, blocked:, degraded:)
      # CI is always locked to MANUAL regardless of opt-in.
      return MANUAL if env.name == ENVIRONMENT_CI
      # Deployment gate blocks AUTO by default; explicit_opt_in overrides it.
      return MANUAL if !explicit_opt_in && blocked.any? { |reason| reason.code == "auto_mode_disabled_for_deployment" }
      return MANUAL if degraded
      return MANUAL if auto_allowed == false
      return explicit_mode if explicit_mode.present? && MODES.include?(explicit_mode)

      # When operator explicitly opted in, allow AUTO even for environments
      # whose default_mode is MANUAL (e.g. unknown/remote deployments).
      return AUTO if explicit_opt_in && auto_allowed

      env.default_mode == AUTO ? AUTO : MANUAL
    end

    def effective_max_concurrent(env)
      env.default_max_concurrent
    end
  end
end
