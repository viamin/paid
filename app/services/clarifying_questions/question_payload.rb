# frozen_string_literal: true

module ClarifyingQuestions
  # Normalizes the versioned question payload used by the Inbox. Old string
  # questions remain intact: we do not infer a recommendation or split prose
  # into a product decision after it has already been stored or posted.
  # @spec OPERATOR-INBOX-025
  class QuestionPayload
    FIELDS = %w[question choices choice_type recommendation rationale examples evidence_references].freeze

    def self.call(...)
      new(...).call
    end

    def self.submission_text(question)
      call(question:).fetch(:question)
    end

    def self.submission_texts(questions)
      Array(questions).map { |question| submission_text(question) }
    end

    def self.reconcile(comment_questions:, stored_questions:)
      stored = Array(stored_questions).select { |question| submission_text(question).present? }
      return Array(comment_questions) unless stored.any? && identities(comment_questions) == identities(stored)

      stored
    end

    def self.identities(questions)
      Array(questions).map do |question|
        label = submission_text(question).to_s.split(Choices::ANY_MARKER, 2).first
        AnswerPairs.normalize_question(label)
      end
    end
    private_class_method :identities

    def initialize(question:)
      @question = question
    end

    def call
      return legacy_payload unless question.is_a?(Hash)

      structured_payload
    end

    private

    attr_reader :question

    def legacy_payload
      text = question.to_s.strip
      { question: text, choices: Choices.call(question: text), recommendation: nil,
        rationale: nil, examples: [], evidence_references: [], structured: false }
    end

    def structured_payload
      references = strings_for("evidence_references")
      recommendation = value_for("recommendation") if references.any?
      {
        question: value_for("question"),
        choices: structured_choices,
        recommendation: recommendation,
        rationale: value_for("rationale"),
        examples: strings_for("examples"),
        evidence_references: references,
        structured: true
      }
    end

    def structured_choices
      options = Array(value("choices")).filter_map do |choice|
        next unless choice.is_a?(Hash)

        label = choice["label"] || choice[:label]
        detail = choice["detail"] || choice[:detail] || choice["text"] || choice[:text]
        next if label.to_s.strip.blank?

        { label: label.to_s.strip, text: detail.to_s.strip }
      end
      return if options.size < 2

      { type: structured_choice_type, options: options }
    end

    def structured_choice_type
      choice_type = value_for("choice_type")&.to_sym
      choice_type.in?([ :single, :multi ]) ? choice_type : :single
    end

    def strings_for(key)
      Array(value(key)).filter_map { |item| item.to_s.strip.presence }
    end

    def value_for(key)
      value(key).to_s.strip.presence
    end

    def value(key)
      question[key] || question[key.to_sym]
    end
  end
end
