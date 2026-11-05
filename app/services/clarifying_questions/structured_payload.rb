# frozen_string_literal: true

module ClarifyingQuestions
  # Sanitizes the clarifying-question payload the enhancement agent emits
  # next to its comment body.
  #
  # The agent is an untrusted producer: the payload is sanitized before it is
  # persisted or rendered, and a malformed payload never fails the run — the
  # questions still publish and the clarification falls back to the legacy
  # rendering.
  #
  # Rules:
  #
  # - only object entries with a non-blank `question` survive,
  # - `choices` entries need a non-blank `label`; a choice list with fewer
  #   than two usable options is dropped instead of rendering a one-button
  #   choice,
  # - `multiple` marks a multi-answer question (`true` only),
  # - `recommendation` needs a non-blank `label`,
  # - `rationale` is a string, `examples` and `evidence` are lists of
  #   strings, and blank values are dropped.
  #
  # The agent's JSON arrives with symbolized keys in the activity and with
  # string keys once persisted, so both spellings are read.
  # @spec ISSUE-ENHANCEMENT-020
  class StructuredPayload
    MIN_CHOICES = 2

    def self.call(...)
      new(...).call
    end

    def initialize(payload:)
      @payload = payload
    end

    def call
      return [] unless payload.is_a?(Array)

      payload.filter_map { |entry| sanitize(entry) }
    end

    private

    attr_reader :payload

    def sanitize(entry)
      return nil unless entry.is_a?(Hash)

      question = value(entry, "question").to_s.strip
      return nil if question.blank?

      sanitized = { "question" => question }
      sanitized["choices"] = choices(entry) if choices(entry)
      sanitized["multiple"] = true if multiple?(entry)
      sanitized["recommendation"] = recommendation(entry) if recommendation(entry)
      sanitized["rationale"] = rationale(entry) if rationale(entry)
      sanitized["examples"] = examples(entry) if examples(entry).any?
      sanitized["evidence"] = evidence(entry) if evidence(entry).any?

      sanitized
    end

    def choices(entry)
      raw_choices = value(entry, "choices")
      return nil unless raw_choices.is_a?(Array)

      options = raw_choices.filter_map do |choice|
        next unless choice.is_a?(Hash)

        label = value(choice, "label").to_s.strip
        next if label.blank?

        { "label" => label, "text" => value(choice, "text").to_s.strip }
      end
      return nil if options.size < MIN_CHOICES

      options
    end

    def multiple?(entry)
      [ true, "true" ].include?(value(entry, "multiple"))
    end

    def recommendation(entry)
      raw_recommendation = value(entry, "recommendation")
      return nil unless raw_recommendation.is_a?(Hash)

      label = value(raw_recommendation, "label").to_s.strip
      return nil if label.blank?

      { "label" => label, "text" => value(raw_recommendation, "text").to_s.strip }
    end

    def rationale(entry)
      value(entry, "rationale").to_s.strip.presence
    end

    def examples(entry)
      strings(entry, "examples")
    end

    def evidence(entry)
      strings(entry, "evidence")
    end

    def strings(entry, key)
      raw_values = value(entry, key)
      return [] unless raw_values.is_a?(Array)

      raw_values.filter_map { |item| item.to_s.strip.presence }
    end

    def value(hash, key)
      return hash[key.to_s] if hash.key?(key.to_s)
      return hash[key.to_sym] if hash.key?(key.to_sym)

      nil
    end
  end
end
