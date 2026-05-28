# frozen_string_literal: true

module AgentRunPatterns
  class AutoApply
    COOLDOWN_WINDOW = 24.hours

    def self.call(...)
      new(...).call
    end

    def initialize(decision:, pattern:)
      @decision = decision
      @pattern = pattern
    end

    def call
      return decision unless auto_apply_enabled?
      return decision unless threshold_met?
      return decision if auto_apply_cooldown_active?
      return decision if downgraded_to_notify_only?

      ApplyDecision.call(decision: decision, pattern: pattern)
    end

    private

    attr_reader :decision, :pattern

    def auto_apply_enabled?
      policy.fetch("mode") == "auto_apply"
    end

    def threshold_met?
      decision.confidence.to_f >= policy.fetch("minimum_confidence").to_f &&
        decision.occurrence_count >= policy.fetch("filing_threshold").to_i
    end

    def auto_apply_cooldown_active?
      decision.account.remediation_decisions
        .where.not(id: decision.id)
        .where(fingerprint: decision.fingerprint, proposed_action: decision.proposed_action, status: "applied")
        .where("COALESCE(applied_at, created_at) >= ?", COOLDOWN_WINDOW.ago)
        .exists?
    end

    def downgraded_to_notify_only?
      decision.account.remediation_decisions
        .where.not(id: decision.id)
        .where(fingerprint: decision.fingerprint, proposed_action: decision.proposed_action)
        .where(outcome: %w[unchanged regressed])
        .exists?
    end

    def policy
      @policy ||= decision.account.remediation_policy_for(decision.proposed_action)
    end
  end
end
