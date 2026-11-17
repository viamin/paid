# frozen_string_literal: true

module FeatureIntents
  # Records an explicit human response against the decision that raised it.
  # @spec FACET-CONFIDENCE-019
  class RespondToDecision
    class InvalidResponseError < StandardError; end
    class StaleDecisionError < StandardError; end

    def self.call(...) = new(...).call

    def initialize(decision:, actor:, answer:)
      @decision = decision
      @actor = actor
      @answer = answer.to_s.strip
    end

    def call
      raise InvalidResponseError, "Enter a response." if answer.blank?
      raise InvalidResponseError, "Responses must be #{ResponseDrafts::MAX_ANSWER_CHARS} characters or fewer." if answer.length > ResponseDrafts::MAX_ANSWER_CHARS

      decision.with_lock do
        raise StaleDecisionError, "This decision was already resolved. Reload to review its current state." unless decision.open?

        decision.resolve!(by: actor, answer:)
        settle_checkpoint_if_complete
        ProjectDelegation::RecordPilotEvent.human_decision(decision)
      end
    end

    private

    attr_reader :answer, :actor, :decision

    def settle_checkpoint_if_complete
      checkpoint = decision.intent_checkpoint
      return unless checkpoint&.status == "open"

      # Serialize the completion check on the checkpoint: concurrent answers
      # to the final questions each lock only their own decision, so an
      # unlocked check could see the other answer as still open and skip
      # settlement in both transactions. The row lock is held until the
      # enclosing decision transaction commits, so the request that acquires
      # it last observes every earlier answer committed and settles.
      checkpoint.with_lock do
        next unless checkpoint.status == "open"
        next unless checkpoint.questions.reload.all? { |question| question.status == "resolved" }

        ProjectDelegation::IntentCheckpoint::Settle.call(
          checkpoint:, actor:, answers: checkpoint.questions.to_h { |question| [ question.id, question.answer ] },
          design_revision: checkpoint.proposed_design_revision,
          acceptance_revision: checkpoint.proposed_acceptance_revision
        )
      end
    end
  end
end
