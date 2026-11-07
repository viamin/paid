# frozen_string_literal: true

module ProjectDelegation
  # Checks whether an action class is delegated to Paid or requires a human decision.
  # This service is called by action admission boundaries to determine if Paid may
  # make this decision autonomously under the project's delegation posture.
  #
  # Currently, all actions are considered NOT delegated (conservative behavior)
  # until the project_delegation feature gate is enabled and the project opts in.
  #
  # @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-005
  class ActionPermit
    DELEGABLE_ACTIONS = %w[
      implementation_choice
      follow_up_recording
      technical_stop_recovery
      evidence_gated_closeout
      cycle_analysis_and_repair
    ].freeze

    attr_reader :project, :action_class

    def initialize(project:, action_class:)
      @project = project
      @action_class = action_class
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        delegated: delegated?,
        reason: reason,
        posture: projection.posture,
        action_enabled: action_enabled?
      }
    end

    def delegated?
      return false unless delegation_enabled?
      return false if projection.conservative?

      enabled_actions.fetch(action_class, false)
    end

    private

    def projection
      @projection ||= ProjectDelegation::Projection.call(project)
    end

    def enabled_actions
      projection.enabled_actions
    end

    def action_enabled?
      enabled_actions.fetch(action_class, false)
    end

    def delegation_enabled?
      # Future: check automation_phases flag and project_delegation feature gate
      # For now, delegation is disabled until the feature is fully implemented
      false
    end

    def reason
      return :feature_disabled unless delegation_enabled?
      return :posture_conservative if projection.conservative?
      return :action_not_enabled unless action_enabled?

      :delegated
    end
  end
end
