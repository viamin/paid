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
      documents_with_pointers.map { |document| document[:text] }
    end

    def documents_with_pointers
      [].tap do |documents|
        outer_errors.each_with_index do |message, index|
          next if message.blank?

          documents << { pointer: "outer_errors[#{index}]", text: message }
        end

        runner_attempts.each_with_index do |attempt, index|
          add_attempt_document(documents, attempt, index)
        end

        log_tails.each_with_index do |tail, index|
          add_log_documents(documents, tail, index)
        end

        # Runner configs remain available via `to_payload`, but excluding them
        # here prevents contextual metadata from diluting diagnosis confidence.
      end
    end

    def allowed_pointers
      documents_with_pointers.map { |document| document[:pointer] }
    end

    def text_for_pointer(pointer)
      documents_with_pointers.find { |document| document[:pointer] == pointer }&.dig(:text)
    end

    private

    def add_attempt_document(documents, attempt, index)
      {
        "runner_attempts[#{index}].error_message" => attempt[:error_message],
        "runner_attempts[#{index}].diagnostics" => attempt[:diagnostics].presence&.to_json
      }.each do |pointer, value|
        next if value.blank?

        documents << {
          pointer: pointer,
          text: [
            attempt[:runner],
            attempt[:error_type],
            value
          ].compact.join("\n")
        }
      end
    end

    def add_log_documents(documents, tail, index)
      {
        "log_tails[#{index}].stdout" => tail[:stdout],
        "log_tails[#{index}].stderr" => tail[:stderr]
      }.each do |pointer, value|
        next if value.blank?

        documents << { pointer: pointer, text: value }
      end
    end
  end
end
