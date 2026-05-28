# frozen_string_literal: true

module AgentRunPatterns
  class Diagnose
    ROOT_CAUSE_CATEGORIES = {
      llm_provider: {
        patterns: [
          /no llm provider/i,
          /provider.*error/i,
          /model.*not.*found/i,
          /api.*key.*invalid/i,
          /authentication.*fail/i,
          /quota.*exceeded/i,
          /context.*length.*exceed/i,
          /token.*limit.*exceed/i
        ],
        label: "LLM Provider Error",
        remediation: "Check provider health and credentials. Consider retrying with an alternate transport or model."
      },
      github_api: {
        patterns: [
          /github.*api.*error/i,
          /rate.?limit/i,
          /token.*expired/i,
          /oauth.*session.*expired/i,
          /permission.*denied/i,
          /branch.*protection/i,
          /merge.*conflict/i
        ],
        label: "GitHub API Error",
        remediation: "Check GitHub token health, rate limit status, and repository permissions."
      },
      container: {
        patterns: [
          /container.*error/i,
          /docker.*error/i,
          /oci.*runtime.*error/i,
          /cannot allocate memory/i,
          /no space left on device/i,
          /container.*exit/i,
          /exec format error/i
        ],
        label: "Container Error",
        remediation: "Check Docker availability, resource limits, and container image integrity."
      },
      timeout: {
        patterns: [
          /timeout/i,
          /timed?\s*out/i,
          /deadline.*exceeded/i,
          /execution.*expired/i
        ],
        label: "Timeout",
        remediation: "Check queue depth, resource contention, and whether the task scope is too large."
      }
    }.freeze

    Diagnosis = Data.define(:root_cause, :category, :confidence, :remediation)

    def self.call(pattern)
      new(pattern).call
    end

    def initialize(pattern)
      @pattern = pattern
    end

    def call
      evidence_documents = extract_evidence_documents
      return unknown_diagnosis if evidence_documents.empty?

      matches = classify_errors(evidence_documents)
      return unknown_diagnosis if matches.empty?

      best_match = matches.max_by { |_, score| score }
      category_key = best_match.first
      category = ROOT_CAUSE_CATEGORIES[category_key]

      Diagnosis.new(
        root_cause: category[:label],
        category: category_key.to_s,
        confidence: [ best_match.last.to_f / evidence_documents.size, 1.0 ].min,
        remediation: category[:remediation]
      )
    end

    private

    attr_reader :pattern

    def extract_evidence_documents
      evidence_bundle = pattern.details[:evidence_bundle]
      return EvidenceBundle.from_payload(evidence_bundle).documents if evidence_bundle.present?

      details = pattern.details
      Array(details[:error_messages] || details[:sample_messages])
    end

    def classify_errors(evidence_documents)
      matches = Hash.new(0)

      evidence_documents.each do |document|
        ROOT_CAUSE_CATEGORIES.each do |category_key, config|
          score = config[:patterns].any? { |pat| document.match?(pat) } ? 1 : 0
          matches[category_key] += score if score.positive?
        end
      end

      matches
    end

    def unknown_diagnosis
      Diagnosis.new(
        root_cause: "Unknown",
        category: "unknown",
        confidence: 0.0,
        remediation: "Manual investigation required. Review individual agent run logs for details."
      )
    end
  end
end
