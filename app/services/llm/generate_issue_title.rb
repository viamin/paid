# frozen_string_literal: true

module Llm
  # Generates a concise GitHub issue title from agent output using
  # agent_harness. On errors, logs a warning and returns nil so callers
  # can fall back to a default title and issue creation is never blocked.
  #
  # @example
  #   title = Llm::GenerateIssueTitle.call(summary: "# Auth Analysis\n\nThe auth system...")
  #   # => "Authentication system security review"
  class GenerateIssueTitle
    MODEL = "claude-haiku-4-5-20251001"
    MAX_TITLE_LENGTH = 255
    MAX_SUMMARY_INPUT = 4000
    TIMEOUT = 30

    class << self
      def call(summary:)
        new(summary: summary).generate
      end
    end

    def initialize(summary:)
      @summary = summary
    end

    def generate
      return nil if @summary.blank?

      title = request_title
      title.present? ? title.truncate(MAX_TITLE_LENGTH) : nil
    rescue AgentHarness::Error => e
      Rails.logger.warn(
        message: "agent_execution.llm_generate_issue_title_failed",
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    private

    def request_title
      response = AgentHarness.send_message(prompt, provider: :claude, model: MODEL, timeout: TIMEOUT)
      return nil unless response.success?

      clean_title(response.output)
    end

    def prompt
      truncated = @summary.truncate(MAX_SUMMARY_INPUT, omission: "")
      <<~PROMPT.strip
        Generate a concise GitHub issue title for the following agent output. Respond with ONLY the title text — no quotes, no prefix, no explanation. Keep it under #{MAX_TITLE_LENGTH} characters.

        #{truncated}
      PROMPT
    end

    def clean_title(text)
      return nil if text.blank?

      text.strip.delete_prefix('"').delete_suffix('"').strip.presence
    end
  end
end
