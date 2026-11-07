# frozen_string_literal: true

module ProjectDelegation
  # RDR-080 project delegation posture: one normalized read model describing
  # how far Paid may take downstream decisions on its own after intent is
  # settled. Every project defaults to `conservative`; a broader posture
  # exists only as an explicit, authorized selection, and it stays effective
  # only while both rollout guards (automation_phases plus project_delegation)
  # permit the capability. The posture is an input to
  # Automation::EffectivePolicy surfaces; it never grants execution authority.
  # Intentionally slightly over the ~100-line class target: the State shape
  # and the three resolve outcomes are one read contract.
  #
  # @spec PROJECT-DELEGATION-001
  class Posture
    CONSERVATIVE = "conservative"
    BOUNDED_DELIVERY = "bounded_delivery"
    LEVELS = [ CONSERVATIVE, BOUNDED_DELIVERY ].freeze

    # Action classes RDR-080 delegates under bounded_delivery. Under
    # conservative nothing is delegated: Paid keeps surfacing every
    # downstream decision in the Inbox.
    DELEGATED_ACTION_CLASSES = %w[
      bounded_implementation_choice
      focused_followup_ownership
      technical_stop_recovery
      evidence_gated_issue_closure
      cycle_analysis_and_repair
    ].freeze

    # Effective posture for a project: the stored selection when the guards
    # permit it, otherwise the conservative default. `source` names where the
    # effective answer came from so the rendered setting can show it.
    State = Data.define(:level, :source, :revision, :enabled_action_classes, :policy_signature,
      :selected_by_id, :selected_at, :remaining_reviews) do
      def conservative? = level == CONSERVATIVE
      def bounded_delivery? = level == BOUNDED_DELIVERY

      def to_h
        {
          level: level,
          source: source,
          revision: revision,
          enabled_action_classes: enabled_action_classes,
          policy_signature: policy_signature,
          selected_by_id: selected_by_id,
          selected_at: selected_at&.iso8601,
          remaining_reviews: remaining_reviews
        }
      end
    end

    class << self
      def resolve(project)
        record = project.delegation_posture
        return default_state(project) if record.nil?
        return selected_state(record) if guards_enabled?(project)

        # A stored broadened selection never survives its guards being off:
        # the effective posture falls back to conservative (the RDR-080
        # rollback behavior) while the record and its audit history stay
        # intact.
        default_state(project).with(source: "guard_disabled")
      end

      # Both required guards (RDR-080 rollout): the existing automation_phases
      # rollout and the default-off per-project project_delegation gate. The
      # capability stays disabled unless both permit it.
      def guards_enabled?(project)
        Automation::RolloutGuard.enabled?(project) && FeatureFlags.enabled?(:project_delegation, project:)
      end

      # The policy signature a selection pins: a digest of the project's
      # current phase-policy state, the same source every posture signature
      # in the admission contract reads.
      def policy_signature(project)
        Digest::SHA256.hexdigest(Automation::PhaseSettings.call(project).to_h.to_json)
      end

      # Action classes a level delegates; conservative delegates nothing.
      def delegated_classes(level)
        level == BOUNDED_DELIVERY ? DELEGATED_ACTION_CLASSES : []
      end

      def remaining_reviews(level)
        PostureDisplay::REMAINING_REVIEWS.fetch(level, PostureDisplay::REMAINING_REVIEWS[CONSERVATIVE])
      end

      private

      def selected_state(record)
        State.new(
          level: record.level,
          source: "selected",
          revision: record.revision,
          enabled_action_classes: delegated_classes(record.level),
          policy_signature: record.policy_signature,
          selected_by_id: record.selected_by_id,
          selected_at: record.updated_at,
          remaining_reviews: remaining_reviews(record.level)
        )
      end

      def default_state(project)
        State.new(
          level: CONSERVATIVE,
          source: "default",
          revision: 0,
          enabled_action_classes: [],
          policy_signature: policy_signature(project),
          selected_by_id: nil,
          selected_at: nil,
          remaining_reviews: remaining_reviews(CONSERVATIVE)
        )
      end
    end
  end
end
