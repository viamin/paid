# frozen_string_literal: true

require "json"

module FeatureIntents
  # Semantic reviewer judging whether a feature's acceptance criteria are
  # specific enough to tell a future in-scope pull request from drift
  # (RDR-066 "Discovery and approval readiness": "Do not equate a
  # structurally complete RDR with a decision-ready RDR"). The LLM makes the
  # quality judgment (ZFC); this class performs only structural validation.
  # Every failure mode returns nil so the caller fails closed and treats the
  # criteria as unconfirmed.
  # @spec FEATURE-APPROVAL-006
  class CriteriaClarityReview
    include Llm::OutputNormalizer

    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 45
    MIN_CONFIDENCE = 0.55

    Result = Data.define(:clear, :confidence, :explanation) do
      def clear? = clear
    end

    PROMPT = <<~PROMPT
      You are checking whether a feature's acceptance criteria are clear
      enough to gate an implementation-approval decision.

      Feature brief:
      %{brief}

      Linked issue titles and descriptions:
      %{criteria}

      Return exactly one JSON object with these keys:
      - confidence: number between 0.0 and 1.0
      - clear: boolean — true only if the criteria are specific and checkable
        enough that a reviewer could tell whether a future pull request is
        in scope or is drift beyond what was approved.
      - explanation: short free-text reason for humans (required when clear
        is false; explain what is missing or ambiguous).

      Rules:
      - "clear" requires concrete, checkable criteria — not vague language
        like "improve", "handle edge cases appropriately", or "as needed".
      - Do not include markdown, prose, or extra keys.
    PROMPT

    def self.call(...)
      new(...).call
    end

    def initialize(feature_intent:)
      @feature_intent = feature_intent
    end

    def call
      response = AgentHarness.send_message(
        prompt_for,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **Llm::TextMode.options
      )

      return log_failure("unsuccessful_response") unless response.success?

      parsed = parse_json(response.output)
      return log_failure("invalid_json") unless parsed

      validate(parsed)
    rescue AgentHarness::Error => e
      Rails.logger.warn(
        message: "feature_intents.criteria_clarity_review_failed",
        feature_intent_id: feature_intent.id,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    private

    attr_reader :feature_intent

    def prompt_for
      format(PROMPT, brief: brief_text, criteria: criteria_text)
    end

    def brief_text
      feature_intent.brief.to_s.strip.presence || "(no brief recorded)"
    end

    def criteria_text
      lines = trusted_issues.map { |issue| "- ##{issue.github_number} #{issue.title}: #{issue.body.to_s.truncate(1000)}" }
      lines.presence&.join("\n") || "(no linked issues yet)"
    end

    # Untrusted issue bodies never reach the prompt (prompt injection risk):
    # only issues from the project's trusted-user allowlist are cited.
    def trusted_issues
      feature_intent.issues.select(&:trusted?)
    end

    def parse_json(output)
      cleaned = strip_markdown_fence(output.to_s.strip)
      return if cleaned.blank?

      parsed = JSON.parse(cleaned)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def validate(payload)
      confidence = parse_confidence(payload)
      return log_failure("invalid_confidence", payload:) unless confidence
      return log_failure("low_confidence", payload:) if confidence < MIN_CONFIDENCE

      clear = payload["clear"]
      return log_failure("invalid_clear", payload:) unless [ true, false ].include?(clear)

      Result.new(clear: clear, confidence: confidence.round(3), explanation: payload["explanation"].to_s)
    end

    def parse_confidence(payload)
      value = Float(payload.fetch("confidence"))
      value.between?(0.0, 1.0) ? value : nil
    rescue ArgumentError, TypeError, KeyError
      nil
    end

    def log_failure(reason, payload: nil)
      Rails.logger.warn(
        message: "feature_intents.criteria_clarity_review_invalid",
        feature_intent_id: feature_intent.id,
        reason: reason,
        raw_output: payload
      )
      nil
    end
  end
end
