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
      end
    end

    private

    attr_reader :answer, :actor, :decision
  end
end
