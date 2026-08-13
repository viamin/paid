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
    include OutputNormalizer

    DEFAULT_MODEL = "claude-haiku-4-5-20251001"
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
      response = AgentHarness.send_message(
        prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **TextMode.options
      )
      return nil unless response.success?

      clean_title(response.output)
    end

    PROMPT_SLUG = "generation.issue_title"

    # Fallback used only if the seeded prompt is missing or deactivated.
    # The active template lives in db/seeds/prompts.rb under PROMPT_SLUG.
    FALLBACK_PROMPT = <<~PROMPT
      Generate a concise GitHub issue title for the following agent output. Respond with ONLY the title text — no quotes, no prefix, no explanation. Keep it under {{max_title_length}} characters.

      {{summary}}
    PROMPT

    def prompt
      vars = {
        max_title_length: MAX_TITLE_LENGTH,
        summary: @summary.truncate(MAX_SUMMARY_INPUT, omission: "")
      }

      # No project: passed — callers don't always have project context, and
      # this prompt is unlikely to need project-level overrides.
      Prompts::Render.call(
        slug: PROMPT_SLUG,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      ).strip
    end

    def clean_title(text)
      return nil if text.blank?

      strip_surrounding_quotes(text.strip).presence
    end
  end
end
