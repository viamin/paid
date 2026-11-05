# frozen_string_literal: true

module ClarifyingQuestions
  # The reader-side contract for clarifying questions.
  #
  # Every clarification — payload-backed or not — is normalized into one
  # `ClarifyingQuestions::Question` with six distinct fields: the question,
  # the offered choices, Paid's recommendation, the rationale, the examples,
  # and the evidence references.
  #
  # Questions are matched to payload entries by their question text. An entry
  # that matches no question is ignored, so a stale payload can never attach
  # its detail to an unrelated question.
  #
  # Compatibility with questions published before the payload existed is a
  # read-time concern:
  #
  # - a legacy marker choice question keeps its parsed choices, and its label
  #   is the text before the first marker,
  # - a legacy prose question keeps its full text as the label,
  # - nothing is inferred from prose. Paid does not guess a product answer,
  #   so a question without a payload carries no recommendation, rationale,
  #   examples, or evidence.
  # @spec ISSUE-ENHANCEMENT-020
  # @spec ISSUE-ENHANCEMENT-021
  class Normalize
    def self.call(...)
      new(...).call
    end

    def initialize(questions:, details: nil)
      @questions = Array(questions)
      @details = Array(details)
    end

    def call
      questions.map { |raw| build(raw) }
    end

    private

    attr_reader :questions, :details

    def build(raw)
      label = Choices.label_for(raw)
      detail = detail_for(label, raw)
      choices = payload_choices(detail) || Choices.call(question: raw)

      Question.new(
        raw: raw,
        question: label,
        choices: choices,
        recommendation: recommendation(detail, choices),
        rationale: detail && detail["rationale"],
        examples: detail && detail["examples"],
        evidence: detail && detail["evidence"]
      )
    end

    def detail_for(label, raw)
      details.find do |detail|
        matches?(detail, label) || matches?(detail, raw)
      end
    end

    def matches?(detail, text)
      question = detail["question"].to_s
      return false if question.blank?

      normalize_text(question) == normalize_text(text)
    end

    def normalize_text(text)
      text.to_s.strip.gsub(/\s+/, " ")
    end

    def payload_choices(detail)
      return nil unless detail

      options = Array(detail["choices"]).map do |choice|
        { label: choice["label"].to_s, text: choice["text"].to_s }
      end
      return nil if options.size < Choices::MIN_OPTIONS

      { type: detail["multiple"] ? :multi : :single, options: options }
    end

    # A recommendation is only shown when it is grounded: it names an option
    # the question actually offers and the question carries at least one
    # evidence reference. An ungrounded recommendation is omitted rather than
    # shown as an unsourced suggestion.
    def recommendation(detail, choices)
      return nil unless detail

      raw_recommendation = detail["recommendation"]
      return nil unless raw_recommendation.is_a?(Hash)

      label = raw_recommendation["label"].to_s.strip
      return nil if label.blank?
      return nil if Array(detail["evidence"]).empty?
      return nil unless offered?(label, choices)

      { label: label, text: raw_recommendation["text"].to_s }
    end

    def offered?(label, choices)
      return true if choices.nil?

      choices[:options].any? { |option| option[:label].to_s.casecmp?(label) }
    end
  end
end
