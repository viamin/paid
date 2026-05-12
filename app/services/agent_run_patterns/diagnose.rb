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
      error_messages = extract_error_messages
      return unknown_diagnosis if error_messages.empty?

      matches = classify_errors(error_messages)
      return unknown_diagnosis if matches.empty?

      best_match = matches.max_by { |_, count| count }
      category_key = best_match.first
      category = ROOT_CAUSE_CATEGORIES[category_key]

      Diagnosis.new(
        root_cause: category[:label],
        category: category_key.to_s,
        confidence: best_match.last.to_f / error_messages.size,
        remediation: category[:remediation]
      )
    end

    private

    attr_reader :pattern

    def extract_error_messages
      details = pattern.details
      Array(details[:error_messages] || details[:sample_messages])
    end

    def classify_errors(error_messages)
      matches = Hash.new(0)

      error_messages.each do |msg|
        ROOT_CAUSE_CATEGORIES.each do |category_key, config|
          if config[:patterns].any? { |pat| msg.match?(pat) }
            matches[category_key] += 1
          end
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
