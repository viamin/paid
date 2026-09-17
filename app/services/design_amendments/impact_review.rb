# frozen_string_literal: true

require "json"

module DesignAmendments
  # Semantic reviewer that maps a design amendment's changed claims onto the
  # feature's branches (RDR-067 §Revision impact). The LLM makes the semantic
  # judgment; this class performs only structural validation (ZFC): known
  # branch ids, terminal outcome enum, cited claims drawn from the provided
  # claim list, and a confidence floor. Every failure mode returns nil so the
  # caller fails closed and holds every branch for a human.
  # @spec INTENT-AMENDMENT-005
  class ImpactReview
    include Llm::OutputNormalizer

    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 45
    MIN_CONFIDENCE = 0.55
    IMPACTS = %w[affected unaffected uncertain].freeze

    Result = Data.define(:mapping, :confidence) do
      # mapping: { issue_id (Integer) => { impact:, cited_claims:, explanation: } }
    end

    PROMPT = <<~PROMPT
      You are mapping a design amendment's impact onto a feature's branches.

      The amended design changed these claims (cite only from this list):
      %{claims}

      Branches (id, kind, title):
      %{branches}

      Return exactly one JSON object with these keys:
      - confidence: number between 0.0 and 1.0
      - branches: array of objects, one per branch you can assess, each with:
        - id: the branch id copied exactly from the list
        - impact: one of "affected", "unaffected", "uncertain"
        - cited_claims: claims copied exactly from the changed-claims list
        - explanation: short free-text reason for humans

      Rules:
      - A branch is "affected" when it implements or depends on a changed claim.
      - Choose "uncertain" — never "unaffected" — when you cannot establish impact confidently.
      - Omit branches you cannot assess at all; they are treated as uncertain.
      - Do not include markdown, prose, or extra keys.
    PROMPT

    def self.call(...)
      new(...).call
    end

    def initialize(amendment:, branches:)
      @amendment = amendment
      @branches = branches
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
        message: "design_amendments.impact_review_failed",
        project_id: amendment.project_id,
        design_amendment_id: amendment.id,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    private

    attr_reader :amendment, :branches

    def prompt_for
      format(
        PROMPT,
        claims: claims.map { |claim| "- #{claim}" }.join("\n"),
        branches: trusted_branches.map { |branch| branch_line(branch) }.join("\n")
      )
    end

    # Branches from untrusted GitHub authors never reach the prompt — their
    # titles are untrusted input and could steer the LLM's classification
    # (prompt injection). They are force-mapped to "uncertain" in #validate
    # instead, so they still fail closed for a human to review.
    def trusted_branches
      branches.select { |branch| branch[:issue].trusted? }
    end

    def branch_line(branch)
      issue = branch[:issue]
      "- id: #{issue.id} | kind: #{branch[:kind]} | title: #{issue.title.to_s.tr("\n", " ")}"
    end

    def claims
      Array(amendment.drift_evidence["changed_claims"]).map(&:to_s).reject(&:blank?)
    end

    def parse_json(output)
      cleaned = strip_markdown_fence(output.to_s.strip)
      return if cleaned.blank?

      JSON.parse(cleaned)
    rescue JSON::ParserError
      nil
    end

    def validate(payload)
      confidence = parse_confidence(payload)
      return log_failure("invalid_confidence", payload:) unless confidence
      return log_failure("low_confidence", payload:) if confidence < MIN_CONFIDENCE

      raw_branches = payload["branches"]
      return log_failure("invalid_branches", payload:) unless raw_branches.is_a?(Array)

      mapping = default_uncertain_mapping
      raw_branches.each do |raw|
        entry = validate_entry(raw)
        return log_failure("invalid_branch_entry", payload:) unless entry

        mapping[entry[:issue_id]] = entry[:assessment]
      end

      mapping.merge!(untrusted_uncertain_mapping)

      Result.new(mapping:, confidence: confidence.round(3))
    rescue KeyError, ArgumentError, TypeError
      log_failure("invalid_structured_output", payload:)
    end

    def parse_confidence(payload)
      value = Float(payload.fetch("confidence"))
      value.between?(0.0, 1.0) ? value : nil
    rescue ArgumentError, TypeError, KeyError
      nil
    end

    def validate_entry(raw)
      entry = raw.is_a?(Hash) ? raw.deep_stringify_keys : nil
      return unless entry

      issue_id = entry["id"].to_i
      return unless branch_ids.include?(issue_id)

      impact = entry["impact"].to_s
      return unless IMPACTS.include?(impact)

      cited_claims = Array(entry["cited_claims"]).map(&:to_s).reject(&:blank?)
      return unless (cited_claims - claims).empty?

      explanation = entry["explanation"].to_s
      {
        issue_id: issue_id,
        assessment: {
          impact: impact,
          cited_claims: cited_claims,
          explanation: explanation
        }
      }
    end

    # Branches the reviewer omitted are uncertain (fail closed per branch).
    def default_uncertain_mapping
      branch_ids.to_h { |id| [ id, { impact: "uncertain", cited_claims: [], explanation: "The reviewer did not assess this branch." } ] }
    end

    # Overrides any reviewer verdict for untrusted branches (defense in depth
    # against the model guessing an id it was never shown).
    def untrusted_uncertain_mapping
      branches.reject { |branch| branch[:issue].trusted? }.to_h do |branch|
        [ branch[:issue].id, { impact: "uncertain", cited_claims: [], explanation: "Branch author is not on the project's trusted allowlist; excluded from automated impact review." } ]
      end
    end

    def branch_ids
      @branch_ids ||= branches.map { |branch| branch[:issue].id }.to_set
    end

    def log_failure(reason, payload: nil)
      Rails.logger.warn(
        message: "design_amendments.impact_review_invalid",
        project_id: amendment.project_id,
        design_amendment_id: amendment.id,
        reason: reason,
        raw_output: payload
      )
      nil
    end
  end
end
