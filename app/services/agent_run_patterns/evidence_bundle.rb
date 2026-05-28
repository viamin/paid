# frozen_string_literal: true

module AgentRunPatterns
  class EvidenceBundle < Data.define(
    :outer_errors,
    :runner_attempts,
    :log_tails,
    :runner_configs,
    :aggregate_stats
  )
    def self.from_payload(payload)
      value = payload.respond_to?(:to_h) ? payload.to_h.deep_symbolize_keys : {}

      new(
        outer_errors: Array(value[:outer_errors]),
        runner_attempts: Array(value[:runner_attempts]),
        log_tails: Array(value[:log_tails]),
        runner_configs: Array(value[:runner_configs]),
        aggregate_stats: value[:aggregate_stats].is_a?(Hash) ? value[:aggregate_stats] : {}
      )
    end

    def to_payload
      {
        outer_errors: outer_errors,
        runner_attempts: runner_attempts,
        log_tails: log_tails,
        runner_configs: runner_configs,
        aggregate_stats: aggregate_stats
      }
    end

    def documents
      [].tap do |docs|
        outer_errors.each do |message|
          docs << message if message.present?
        end

        runner_attempts.each do |attempt|
          docs << [
            attempt[:runner],
            attempt[:error_type],
            attempt[:error_message],
            attempt[:diagnostics].presence&.to_json
          ].compact.join("\n")
        end

        log_tails.each do |tail|
          docs << [ tail[:stdout], tail[:stderr] ].compact.join("\n")
        end

        # Runner configs remain available via `to_payload`, but excluding them
        # here prevents contextual metadata from diluting diagnosis confidence.
      end.reject(&:blank?)
    end
  end
end
