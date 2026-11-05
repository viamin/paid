# frozen_string_literal: true

module ClarifyingQuestions
  # One normalized clarification: the question the operator answers plus the
  # supporting detail the producer attached to it.
  #
  # The six payload fields stay distinct on the reader side:
  #
  # - `question` — the short label the operator reads and answers,
  # - `choices` — the offered answers (`{ type:, options: }`) or nil,
  # - `recommendation` — Paid's grounded suggestion (`{ label:, text: }`) or nil,
  # - `rationale` — why the agent is asking,
  # - `examples` — what an answer looks like,
  # - `evidence` — the code, issue, or doc references behind the question.
  #
  # `raw` is the canonical question string the platform stores and submits;
  # it stays byte-identical so the answer-form tamper guard and the answer
  # reconciliation keep working for both legacy and structured questions.
  # @spec ISSUE-ENHANCEMENT-020
  class Question
    attr_reader :raw, :question, :choices, :recommendation, :rationale, :examples, :evidence

    def initialize(raw:, question:, choices: nil, recommendation: nil, rationale: nil, examples: nil, evidence: nil)
      @raw = raw
      @question = question
      @choices = choices
      @recommendation = recommendation
      @rationale = rationale
      @examples = examples
      @evidence = evidence
    end

    def choices?
      !choices.nil?
    end

    def recommendation?
      !recommendation.nil?
    end

    # True when the clarification carries detail the operator may want to
    # read before answering. The detail renders inside a closed disclosure,
    # so this only decides whether the disclosure exists at all.
    def supporting_details?
      rationale.present? || examples.present? || evidence.present?
    end
  end
end
