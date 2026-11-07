# frozen_string_literal: true

module ProjectDelegation
  module IntentCheckpoint
    # Records a human settlement of an intent checkpoint (RDR-080): settle,
    # reject, or amend the grouped questions. The resulting answers are
    # immutable and bound to the design and acceptance revision current at
    # settlement, so a downstream boundary can honor the settled answer
    # without re-asking unless the bound revision changes.
    # @spec PROJECT-DELEGATION-002
    class Settle
      class Error < StandardError; end
      class InvalidSettlement < Error; end

      def self.call(...)
        new(...).call
      end

      def initialize(checkpoint:, user:, disposition:, answers: {})
        @checkpoint = checkpoint
        @user = user
        @disposition = disposition.to_s
        @answers = answers.to_h.deep_stringify_keys
      end

      def call
        checkpoint.with_lock do
          ensure_settleable!
          ensure_answers_cover_groups!

          revisions = Revisions.for(checkpoint.issue)
          checkpoint.update!(
            status: terminal_status,
            disposition: disposition,
            answers: bound_answers,
            design_revision: revisions["design_revision"],
            acceptance_revision: revisions["acceptance_revision"],
            settled_by: user,
            settled_at: Time.current
          )
          resolve_source_decisions
          resolve_request
          record_audit
        end

        checkpoint.reload
      end

      private

      attr_reader :checkpoint, :user, :disposition, :answers

      def terminal_status
        disposition == "rejected" ? "rejected" : "settled"
      end

      def ensure_settleable!
        unless ::IntentCheckpoint::DISPOSITIONS.include?(disposition)
          raise InvalidSettlement, "disposition must be one of #{::IntentCheckpoint::DISPOSITIONS.join(", ")}"
        end
        return if checkpoint.pending?

        raise InvalidSettlement, "only a pending checkpoint can be settled"
      end

      # A settlement answers every group or names an explicit rejection.
      def ensure_answers_cover_groups!
        return if disposition == "rejected"

        missing = checkpoint.group_keys.reject { |key| answers[key].present? }
        return if missing.empty?

        raise InvalidSettlement, "answers required for group(s): #{missing.join(", ")}"
      end

      # Rejections may carry an optional note; keep answers limited to the
      # checkpoint's own group keys so the binding stays reviewable.
      def bound_answers
        return answers.slice(*checkpoint.group_keys) if disposition == "rejected"

        answers
      end

      # Settling a checkpoint derived from RDR-066 decisions resolves those
      # decisions with the group's answer, so the existing approval surfaces
      # never see the question twice.
      def resolve_source_decisions
        FeatureIntentDecision.where(id: source_decision_ids).find_each do |decision|
          decision.resolve!(by: user, answer: answer_for_decision(decision))
        end
      end

      def source_decision_ids
        checkpoint.groups.flat_map { |group| Array(group["source_decision_ids"]) }.uniq
      end

      def answer_for_decision(decision)
        group = checkpoint.groups.find do |candidate|
          Array(candidate["source_decision_ids"]).include?(decision.id)
        end
        answers.fetch(group["key"], decision.prompt.to_s)
      end

      def resolve_request
        Notifications::Resolve.call(
          account: checkpoint.account,
          source: Plan::NOTIFICATION_SOURCE,
          subject: checkpoint.issue
        )
      end

      def record_audit
        Audit::RecordEvent.call(
          action: "intent_checkpoint.settled",
          actor: user,
          subject: checkpoint,
          metadata: {
            "disposition" => disposition,
            "design_revision" => checkpoint.design_revision,
            "acceptance_revision" => checkpoint.acceptance_revision,
            "group_keys" => checkpoint.group_keys
          }
        )
      end
    end
  end
end
