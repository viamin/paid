# frozen_string_literal: true

module ProjectDelegation
  class IntentCheckpoint
    # @spec PROJECT-DELEGATION-002
    class Settle
      def self.call(...) = new(...).call

      def initialize(checkpoint:, actor:, answers:, design_revision:, acceptance_revision:, disposition: "settled")
        @checkpoint, @actor, @answers = checkpoint, actor, answers.to_h.stringify_keys
        @design_revision, @acceptance_revision, @disposition = design_revision, acceptance_revision, disposition
      end

      def call
        checkpoint.with_lock do
          raise ArgumentError, "Intent checkpoint has already been settled" unless checkpoint.status == "open"
          validate_answers!
          settlement = checkpoint.settlements.create!(settled_by: actor, disposition:, answers:, design_revision:,
            acceptance_revision:, settled_at: Time.current)
          checkpoint.update!(status: disposition)
          resolve_open_questions
          settlement
        end
      end

      private

      attr_reader :acceptance_revision, :actor, :answers, :checkpoint, :design_revision, :disposition

      def validate_answers!
        missing = checkpoint.questions.map { |question| question.id.to_s } - answers.keys
        raise ArgumentError, "Every checkpoint question needs an answer" if missing.any?
        raise ArgumentError, "Settlement revisions must be present" if design_revision.blank? || acceptance_revision.blank?
      end

      # Only questions still open are resolved here. The response path
      # (FeatureIntents::RespondToDecision) resolves each question with its
      # actual responder before the final answer settles the checkpoint, so
      # re-resolving would overwrite that durable attribution — and re-enqueue
      # the clarity job — with the settling actor. Already-resolved questions
      # keep their original resolver, answer, and resolved_at.
      def resolve_open_questions
        checkpoint.questions.reload.each do |question|
          next unless question.open?

          question.resolve!(by: actor, answer: answers.fetch(question.id.to_s))
        end
      end
    end
  end
end
