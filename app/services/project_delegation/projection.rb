# frozen_string_literal: true

module ProjectDelegation
  # Shared read model for displaying the effective project delegation posture,
  # enabled action classes, applicable phase policies, stop boundaries, and
  # mandatory review requirements.
  #
  # This projection is used by settings UI, Inbox, API, and MCP to answer:
  # "what decisions may Paid make on behalf of this project?"
  #
  # @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-005
  class Projection
    attr_reader :project

    def initialize(project)
      @project = project
    end

    def self.call(project)
      new(project)
    end

    # The project's currently selected delegation posture
    def posture
      @project.delegation_posture || Project::DEFAULT_DELEGATION_POSTURE
    end

    # When the posture was last selected
    def selected_at
      @project.delegation_posture_selected_at
    end

    # Who selected the posture
    def selected_by
      @project.delegation_posture_selected_by
    end

    # The policy signature at the time of selection
    def policy_signature
      @project.delegation_policy_signature
    end

    # Enabled action classes for this posture
    def enabled_actions
      @project.delegation_enabled_actions || {}
    end

    # Human-facing label for the current posture
    def posture_label
      Project::DELEGATION_POSTURE_LABELS[posture]
    end

    # Is the posture conservative (the default)?
    def conservative?
      posture == "conservative"
    end

    # Is the posture bounded_delivery?
    def bounded_delivery?
      posture == "bounded_delivery"
    end

    # Audit trail of delegation changes
    def events
      @project.project_delegation_events.chronological
    end

    # Most recent delegation event
    def last_event
      @project.project_delegation_events.recent.first
    end

    # All remaining human reviews required by policy
    def remaining_required_reviews
      # This is a placeholder for the full implementation which will analyze
      # the project's RDR-077 phase policy, RDR-078 bounded authorization,
      # repository review rules, and other controls to determine what
      # human reviews remain mandatory.
      {
        phase_approval: true,
        repository_review: true,
        merge_approval: true,
        release_decision: true
      }
    end

    # Can this project use bounded_delivery posture?
    def delegation_eligible?
      # Initially, only opt-in projects can use bounded_delivery
      # This will be gated behind the project_delegation feature flag
      false
    end

    # Is delegation currently enabled for this project and account?
    def delegation_enabled?
      # Future: check automation_phases flag and project_delegation feature gate
      false
    end

    # Summary of the delegation state for UI display
    def summary
      {
        posture:,
        posture_label:,
        selected_at:,
        selected_by: selected_by&.email,
        enabled_actions:,
        remaining_reviews: remaining_required_reviews,
        eligible: delegation_eligible?,
        enabled: delegation_enabled?
      }
    end
  end
end
