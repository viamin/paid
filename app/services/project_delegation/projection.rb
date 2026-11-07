# frozen_string_literal: true

module ProjectDelegation
  # Shared read model for project delegation settings, used by UI, API, MCP,
  # and all execution surfaces. Shows effective posture, source/revision,
  # enabled action classes, applicable phases, and mandatory review requirements.
  #
  # @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-005
  class Projection
    CONSERVATIVE_POSTURE = "conservative"
    BOUNDED_DELIVERY_POSTURE = "bounded_delivery"

    VALID_POSTURES = [CONSERVATIVE_POSTURE, BOUNDED_DELIVERY_POSTURE].freeze

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(project:)
      new(project:)
    end

    # Current effective posture: defaults to conservative, respects project setting
    def effective_posture
      project.delegation_posture || CONSERVATIVE_POSTURE
    end

    # Timestamp when posture was last authorized
    def authorized_at
      project.delegation_authorized_at
    end

    # User who authorized the current posture
    def authorized_by
      project.delegation_authorized_by
    end

    # Policy signature pinned at authorization time
    def posture_signature
      project.delegation_posture_signature
    end

    # Action classes enabled under current posture
    def enabled_action_classes
      project.delegation_enabled_action_classes || []
    end

    # Is project delegated to execute work autonomously?
    def delegated?
      effective_posture == BOUNDED_DELIVERY_POSTURE
    end

    # Is project in default conservative posture?
    def conservative?
      effective_posture == CONSERVATIVE_POSTURE
    end

    # Mandatory reviews that cannot be delegated
    def mandatory_reviews
      case effective_posture
      when BOUNDED_DELIVERY_POSTURE
        %w[
          feature_intent_approval
          acceptance_criteria_review
          repository_review_merge
          release_deployment
          settings_changes
          explicit_holds
        ]
      else
        # conservative posture requires all existing reviews
        %w[
          feature_intent_approval
          acceptance_criteria_review
          repository_review_merge
          release_deployment
          settings_changes
          explicit_holds
          bounded_implementation_choices
          follow_up_recording
          technical_stop_recovery
          evidence_gated_closure
          cycle_analysis
        ]
      end
    end

    # Remaining reviews required for this project/posture combination
    def remaining_reviews
      mandatory_reviews
    end

    def to_h
      {
        effective_posture: effective_posture,
        delegated: delegated?,
        conservative: conservative?,
        authorized_at: authorized_at,
        authorized_by: authorized_by&.name,
        authorized_by_id: authorized_by&.id,
        posture_signature: posture_signature,
        enabled_action_classes: enabled_action_classes,
        mandatory_reviews: mandatory_reviews,
        remaining_reviews: remaining_reviews
      }
    end
  end
end
