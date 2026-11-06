# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Deterministic routing for one downstream material question against the
    # settled-intent record. A question settled at the current design and
    # acceptance revision is answered and must not be re-asked, whatever phase
    # downstream work has reached. A focused re-decision is routed only when
    # the revisions changed AND the caller declares a qualifying conflict
    # (conflicts, invalidates, materially_expands) with supporting evidence;
    # the decision names only the smallest affected question.
    # @spec PROJECT-DELEGATION-002
    class ResolveQuestion
      CONFLICT_REASONS = %w[conflicts invalidates materially_expands].freeze

      Result = Data.define(:status, :group, :answer, :decision, :settlement, :stale, :focused_decision) do
        def settled? = status == :settled
        def redecision? = status == :redecision
        def pending_settlement? = status == :pending_settlement
        def unplanned? = status == :unplanned
        def stale? = stale
        def needs_human? = redecision? || pending_settlement? || unplanned?
      end

      def self.call(...)
        new(...).call
      end

      def initialize(project:, issue: nil, group_key:, design_revision:, acceptance_revision:,
        reason: nil, evidence: [])
        @project = project
        @issue = issue
        @group_key = group_key
        @design_revision = design_revision
        @acceptance_revision = acceptance_revision
        @reason = reason
        @evidence = evidence
      end

      def call
        ensure_inputs!
        return unplanned if containing_checkpoints.empty?

        settlement = latest_settlement
        group = latest_containing_group
        return pending_settlement(group) if settlement.nil?

        answer = settlement.answer_for(group_key)
        return settled(settlement, answer) if bound_to_current_revisions?(settlement)
        return redecision(settlement, answer) if qualifies_for_redecision?

        settled(settlement, answer, stale: true)
      end

      private

      attr_reader :project, :issue, :group_key, :design_revision, :acceptance_revision, :reason, :evidence

      def ensure_inputs!
        raise ArgumentError, "group_key is required." unless group_key.is_a?(String) && group_key.strip.present?
        unless design_revision.is_a?(String) && design_revision.strip.present?
          raise ArgumentError, "design_revision is required."
        end
        unless acceptance_revision.is_a?(String) && acceptance_revision.strip.present?
          raise ArgumentError, "acceptance_revision is required."
        end
      end

      def containing_checkpoints
        @containing_checkpoints ||= ProjectDelegation::Checkpoint
          .where(project: project, issue: issue).order(:id)
          .select { |checkpoint| checkpoint.group_keys.include?(group_key) }
      end

      def latest_containing_group
        containing_checkpoints.last.groups.find { |group| group["key"] == group_key }
      end

      def latest_settlement
        ProjectDelegation::Settlement.where(checkpoint_id: containing_checkpoints.map(&:id)).order(:id).last
      end

      def bound_to_current_revisions?(settlement)
        settlement.design_revision == design_revision && settlement.acceptance_revision == acceptance_revision
      end

      # A re-decision is routed only when the settled revision changed and the
      # caller carries a qualifying conflict with inspectable evidence. Any
      # other downstream stop keeps the settled answer binding.
      def qualifies_for_redecision?
        reason.in?(CONFLICT_REASONS) && evidence.is_a?(Array) &&
          evidence.any? { |reference| reference.is_a?(String) && reference.strip.present? }
      end

      def settled(settlement, answer, stale: false)
        Result.new(status: :settled, group: latest_containing_group, answer: answer,
          decision: settlement.decision, settlement: settlement, stale: stale, focused_decision: nil)
      end

      def pending_settlement(group)
        Result.new(status: :pending_settlement, group: group, answer: nil, decision: nil,
          settlement: nil, stale: false, focused_decision: nil)
      end

      def unplanned
        Result.new(status: :unplanned, group: nil, answer: nil, decision: nil,
          settlement: nil, stale: false, focused_decision: nil)
      end

      def redecision(settlement, answer)
        group = settlement.checkpoint.groups.find { |candidate| candidate["key"] == group_key }
        Result.new(status: :redecision, group: group, answer: answer, decision: settlement.decision,
          settlement: settlement, stale: true, focused_decision: focused_decision(settlement, answer, group))
      end

      def focused_decision(settlement, answer, group)
        {
          "group_key" => group_key,
          "question" => group["question"],
          "recommendation" => group["recommendation"],
          "consequences" => group["consequences"],
          "prior_decision" => settlement.decision,
          "prior_answer" => answer&.fetch("choice", nil),
          "revision_delta" => {
            "design" => { "settled" => settlement.design_revision, "current" => design_revision },
            "acceptance" => { "settled" => settlement.acceptance_revision, "current" => acceptance_revision }
          },
          "reason" => reason,
          "evidence" => evidence,
          "next_action" => "human_decision"
        }
      end
    end
  end
end
