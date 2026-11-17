# frozen_string_literal: true

module ProjectDelegation
  class IntentCheckpoint
    # @spec PROJECT-DELEGATION-002 — shared drift handler behind both
    # revision bindings a settlement pins. A merged design amendment
    # (design delta) and a re-recorded acceptance assessment (acceptance
    # delta) are the two production events that replace a bound revision;
    # both funnel here so every drifted checkpoint gets the same focused,
    # deduplicated re-decision while checkpoints already bound to the
    # event's revisions stay silent (Redecision compares the tuple and
    # collapses equivalent requests).
    class RouteDrift
      def self.on_design_change(feature_intent:, design_revision:)
        new(feature_intent:, design_revision:).route
      end

      # The canonical acceptance token is per-issue, so the re-recorded
      # issue must be one the checkpoint actually binds — an audit of the
      # feature's implementation issues never touches the brief issue's
      # settled acceptance. Resolution uses the same linked-issue lookup
      # the run-decision checkpoint planning binds with.
      def self.on_acceptance_change(issue:)
        return if issue.nil?

        acceptance_revision = Automation::DelegatedActionAdmission.revision_tokens(issue:)["acceptance_revision"]
        FeatureIntent.linked_to_issue(issue).find_each do |feature_intent|
          new(feature_intent:, acceptance_revision:, acceptance_issue: issue).route
        end
      end

      def initialize(feature_intent:, design_revision: nil, acceptance_revision: nil, acceptance_issue: nil)
        @feature_intent = feature_intent
        @design_revision = design_revision
        @acceptance_revision = acceptance_revision
        @acceptance_issue = acceptance_issue
      end

      # Only checkpoints with a settlement carry a durable binding to drift
      # from; an open checkpoint is still awaiting its first human
      # settlement. The revision the event did not change is carried through
      # from each settlement so the comparison stays focused on the event's
      # delta.
      def route
        return if design_revision.blank? && acceptance_revision.blank?

        feature_intent.project_delegation_intent_checkpoints.joins(:settlements).distinct.find_each do |checkpoint|
          route_checkpoint(checkpoint)
        end
      end

      private

      attr_reader :acceptance_issue, :acceptance_revision, :design_revision, :feature_intent

      def route_checkpoint(checkpoint)
        return if acceptance_issue && !checkpoint.binding_issue_ids.include?(acceptance_issue.id)

        settlement = checkpoint.latest_settlement
        Redecision.call(
          checkpoint:,
          design_revision: design_revision || settlement.design_revision,
          acceptance_revision: acceptance_revision || settlement.acceptance_revision
        )
      end
    end
  end
end
