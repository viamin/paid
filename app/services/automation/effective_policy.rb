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
  # @spec AUTOMATION-PHASES-017
  class EffectivePolicy
    SOURCES = %i[legacy_policy manual_action continuation_grant project_defaults].freeze
    REASONS = %i[phase_disabled phase_enabled].freeze

    Decision = Struct.new(:permitted, :source, :reason, :phase, :grant, keyword_init: true) do
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
          grant_id: grant&.id
        }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, phase:, work_item: nil, trigger: :automatic)
      @project = project
      @phase = phase&.to_s
      @work_item = work_item
      @trigger = trigger
    end

    def call
      return permit(:legacy_policy, :phase_enabled) unless enabled?
      return permit(:manual_action, :phase_enabled) if manual_action?

      grant = covering_grant
      return permit(:continuation_grant, :phase_enabled, grant:) if grant
      return permit(:project_defaults, :phase_enabled) if phase_enabled?

      Decision.new(permitted: false, source: nil, reason: :phase_disabled, phase:, grant: nil)
    end

    def permitted?(...)
      call.permitted?
    end

    private

    attr_reader :phase, :project, :trigger, :work_item

    def permit(source, reason, grant: nil)
      Decision.new(permitted: true, source:, reason:, phase:, grant:)
    end

    # Rollout guard: while the flag is off the pre-existing policy applies.
    def enabled?
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
      ContinuationGrantLookup.covering(project:, phase:, work_item:)
    end
  end
end
