# frozen_string_literal: true

module Capacity
  # Structured "why is the queue blocked" payload surfaced to the queue
  # processor and the operator UI. Each reason carries:
  #
  # - an internal `code` for telemetry and tests;
  # - a short `summary` safe to put next to a queued run in the admin UI;
  # - an actionable `hint` describing how the user can recover.
  #
  # All reasons are designed to be returned to non-admin users without
  # exposing Docker container names, internal identifiers, or backend
  # commands. They are intentionally short and never include unrelated
  # container metadata.
  class BlockedReason
    attr_reader :code, :summary, :hint

    def initialize(code:, summary:, hint:)
      @code = code.to_s
      @summary = summary.to_s
      @hint = hint.to_s
    end

    def to_h
      { code: code, summary: summary, hint: hint }
    end

    REASONS = {
      docker_unavailable: new(
        code: "docker_unavailable",
        summary: "Docker capacity is unavailable",
        hint: "Paid could not reach Docker to measure capacity. Start Docker and try again."
      ),
      docker_slow: new(
        code: "docker_slow",
        summary: "Docker capacity check timed out",
        hint: "Docker is responding slower than expected. Paid is using the last known capacity snapshot until Docker responds."
      ),
      docker_low_confidence: new(
        code: "docker_low_confidence",
        summary: "Docker capacity signal is unreliable",
        hint: "Capacity numbers are uncertain; Paid is keeping conservative defaults until Docker reports clean metrics."
      ),
      docker_memory_exhausted: new(
        code: "docker_memory_exhausted",
        summary: "Not enough Docker memory for another run",
        hint: "Docker has no headroom for another agent run. Wait for an active run to finish, raise Docker's memory limit, or stop unrelated containers."
      ),
      auto_mode_disabled_for_deployment: new(
        code: "auto_mode_disabled_for_deployment",
        summary: "Auto capacity is disabled for this deployment",
        hint: "This Paid environment runs against shared or remote Docker, so auto capacity stays off by default. Switch to manual capacity limits or enable auto capacity in tenant settings."
      ),
      auto_mode_degraded: new(
        code: "auto_mode_degraded",
        summary: "Auto capacity is in degraded mode",
        hint: "Paid could not fully inspect Docker, so auto capacity is using conservative manual defaults until metrics recover."
      ),
      cooldown_active: new(
        code: "cooldown_active",
        summary: "Auto capacity is in a tuning cooldown",
        hint: "Capacity was just tuned and is locked for a short window to prevent oscillation. The run will retry when the cooldown expires."
      ),
      unrelated_workload: new(
        code: "unrelated_workload",
        summary: "Docker is busy with unrelated containers",
        hint: "Other containers are using Docker capacity. Paid will start the run when there is enough headroom, or stop the unrelated containers to free memory."
      ),
      oom_history: new(
        code: "oom_history",
        summary: "Recent OOM kills detected",
        hint: "A recent container was OOM-killed. Paid is holding concurrency low while the memory budget recovers."
      ),
      policy_unknown: new(
        code: "policy_unknown",
        summary: "Capacity policy could not be evaluated",
        hint: "Paid could not determine the right capacity policy for this environment. Falling back to manual mode."
      )
    }.freeze

    def self.[](code)
      REASONS.fetch(code.to_sym) { REASONS[:policy_unknown] }
    end

    def self.build(code, **overrides)
      template = self[code]
      BlockedReason.new(
        code: overrides[:code] || template.code,
        summary: overrides[:summary] || template.summary,
        hint: overrides[:hint] || template.hint
      )
    end
  end
end
