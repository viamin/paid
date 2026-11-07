# frozen_string_literal: true

module Automation
  # RDR-077 §4: one effective execution policy for every entry point —
  # schedulers, labels, manual forms, API actions, queue execution, retries,
  # and workflow follow-ups.
  #
  #   1. identify the action's phase, work scope, and required capabilities
  #   2. establish authorization from project defaults, the explicit manual
  #      action, or an applicable continuation grant
  #   3. apply the remaining execution, permission, and safety policies
  #   4. record why the action is permitted or blocked
  #
  # This class owns steps 1, 2, and 4. Step 3 stays with the caller: a grant
  # never bypasses review methods, CI requirements, merge rules, budgets, trust
  # rules, tenant permissions, or scheduler safety holds.
  #
  # @spec AUTOMATION-PHASES-003 @spec AUTOMATION-PHASES-007
  # @spec AUTOMATION-PHASES-017 @spec PROJECT-DELEGATION-004
  class EffectivePolicy
    SOURCES = %i[legacy_policy manual_action continuation_grant project_defaults].freeze
    REASONS = %i[phase_disabled phase_enabled posture_restricted].freeze

    Decision = Struct.new(:permitted, :source, :reason, :phase, :grant, :posture, :phase_policy_signature,
      keyword_init: true) do
      def permitted?
        permitted
      end

      def blocked?
        !permitted
      end

      def to_h
        {
          permitted: permitted?,
          source: source,
          reason: reason,
          phase: phase,
          grant_id: grant&.id,
          phase_policy_signature: phase_policy_signature,
          posture: {
            level: posture.level,
            revision: posture.revision,
            policy_signature: posture.policy_signature
          }
        }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, phase:, work_item: nil, trigger: :automatic, continuation_grants: nil,
      rollout_enabled: nil, delegated_action: nil)
      @project = project
      @phase = phase&.to_s
      @work_item = work_item
      @trigger = trigger
      @continuation_grants = continuation_grants
      @rollout_enabled = rollout_enabled
      @delegated_action = delegated_action
    end

    def call
      return block(:posture_restricted) if delegated_action && !posture.bounded_delivery?
      return permit(:legacy_policy, :phase_enabled) unless enabled?
      return permit(:manual_action, :phase_enabled) if manual_action?

      grant = covering_grant
      return permit(:continuation_grant, :phase_enabled, grant:) if grant
      return permit(:project_defaults, :phase_enabled) if phase_enabled?

      block(:phase_disabled)
    end

    def permitted?(...)
      call.permitted?
    end

    private

    attr_reader :continuation_grants, :delegated_action, :phase, :project, :rollout_enabled, :trigger, :work_item

    def permit(source, reason, grant: nil)
      Decision.new(permitted: true, source:, reason:, phase:, grant:, posture:,
        phase_policy_signature: current_phase_policy_signature)
    end

    def block(reason)
      Decision.new(permitted: false, source: nil, reason:, phase:, grant: nil, posture:,
        phase_policy_signature: current_phase_policy_signature)
    end

    def posture
      @posture ||= ProjectDelegation::Posture.resolve(project)
    end

    def current_phase_policy_signature
      ProjectDelegation::Posture.policy_signature(project)
    end

    # Rollout guard: while the flag is off the pre-existing policy applies.
    def enabled?
      return rollout_enabled unless rollout_enabled.nil?

      Automation::RolloutGuard.enabled?(project)
    end

    # An explicit operator request authorizes the selected action even in a
    # phase whose project default is disabled.
    def manual_action?
      trigger.to_sym == :manual
    end

    def phase_enabled?
      return false if phase.blank?

      PhaseSettings.phase_enabled?(project, phase)
    end

    def covering_grant
      return continuation_grants.find { |grant| grant.covers_phase?(phase) } if continuation_grants

      ContinuationGrantLookup.covering(project:, phase:, work_item:)
    end
  end
end
