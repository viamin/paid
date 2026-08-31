# frozen_string_literal: true

module Llm
  # Generates a structured PR description from the agent's output and issue
  # context using agent_harness. The description leads with "why", summarizes
  # full scope, and surfaces design decisions — following the guidelines in
  # GitHub issue #581.
  #
  # Transient errors (provider failures, timeouts, rate limits) are retried
  # up to MAX_ATTEMPTS times with exponential backoff. After exhausting
  # retries the method returns nil so the caller can fall back to a
  # deterministic description. Non-retryable errors (auth, configuration)
  # and unexpected errors propagate to the caller for contextual logging.
  #
  # @example
  #   body = Llm::GeneratePrDescription.call(
  #     agent_summary: "Added auth middleware...",
  #     issue_title: "Add OAuth support",
  #     issue_body: "We need OAuth for..."
  #   )
  class GeneratePrDescription
    include OutputNormalizer

    DEFAULT_MODEL = "claude-sonnet-4-6"
    MAX_DESCRIPTION_LENGTH = 50_000
    MAX_SUMMARY_INPUT = 20_000
    MAX_ISSUE_BODY_INPUT = 4_000
    TIMEOUT = 30
    MAX_ATTEMPTS = 3
    RETRY_DELAYS = [ 2, 4 ].freeze

    class RequestFailedError < StandardError; end

    RETRYABLE_ERRORS = [
      AgentHarness::ProviderError,
      AgentHarness::TimeoutError,
      AgentHarness::RateLimitError,
      RequestFailedError
    ].freeze

    PROMPT_SLUG = "generation.pr_description"

    # Fallback used only if the seeded prompt is missing or deactivated.
    # The active template lives in db/seeds/prompts.rb under PROMPT_SLUG.
    FALLBACK_PROMPT = <<~PROMPT
      You are writing a pull request description for a code change. Write a clear, well-structured PR description following these rules:

      1. **Lead with "why"** — the first sentence must frame the goal and expected outcome, not implementation details.
      2. **Summarize the full scope** — describe all changes organized by concern (e.g., database, models, services, UI, infrastructure).
      3. **Surface design decisions** — call out important trade-offs, constraints, or choices a reviewer should understand.
      4. **Scale depth to complexity** — keep it concise for small changes; use structured sections for large cross-cutting changes.
      5. **Mention operational concerns** — note any deployment steps, migration notes, or infrastructure changes if relevant.
      6. **Include visuals for UI changes** — if the agent output indicates user-facing UI changes, add a ## Screenshots section with a placeholder reminding the author to attach before/after screenshots.

      Use markdown formatting. Start with a ## Summary section containing 1-3 sentences explaining the purpose. Then add a ## Changes section with a bulleted breakdown organized by concern. If there are notable design decisions, add a ## Design Decisions section. Do NOT include a test plan section.

      Respond with ONLY the PR description markdown — no preamble, no wrapping quotes, no explanation.

      ## Issue Context
      Title: {{issue_title}}
      Body:
      {{issue_body}}

      ## Agent Output
      {{agent_summary}}
    PROMPT

    class << self
      def call(agent_summary:, issue_title: nil, issue_body: nil)
        new(
          agent_summary: agent_summary,
          issue_title: issue_title,
          issue_body: issue_body
        ).generate
      end
    end

    def initialize(agent_summary:, issue_title: nil, issue_body: nil)
      @agent_summary = agent_summary
      @issue_title = issue_title
      @issue_body = issue_body
    end

    def generate
      return nil if @agent_summary.blank?

      description = request_description
      description.present? ? description.truncate(MAX_DESCRIPTION_LENGTH) : nil
    end

    private

    def request_description
      RetryHelper.with_retries(
        max_attempts: MAX_ATTEMPTS,
        retryable: ->(error) { RETRYABLE_ERRORS.any? { |klass| error.is_a?(klass) } },
        delay_fn: ->(attempt, error) { RETRY_DELAYS[attempt - 1] || RETRY_DELAYS.last },
        sleep_fn: method(:sleep)
      ) do
        attempt_single_request
      end
    rescue *RETRYABLE_ERRORS => e
      log_retry_exhausted(e)
      nil
    end

    def attempt_single_request
      response = AgentHarness.send_message(
        prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **TextMode.options
      )

      if response.success?
        normalize_output(response.output).presence
      else
        raise RequestFailedError, response.error
      end
    end

    def log_retry_exhausted(error)
      Rails.logger.info(
        message: "llm.generate_pr_description_retries_exhausted",
        max_attempts: MAX_ATTEMPTS,
        error: "#{error.class.name}: #{error.message}"
      )
    end

    def normalize_output(text)
      return nil if text.nil?

      cleaned = text.strip
      # Iterate until stable: quotes may wrap fences or vice-versa.
      # Try fences first (since backticks overlap with quote pairs),
      # then quotes, and repeat in case quotes were wrapping a fence.
      loop do
        previous = cleaned
        cleaned = strip_markdown_fence(cleaned)
        cleaned = strip_surrounding_quotes(cleaned)
        break if cleaned == previous
      end
      cleaned
    end

    def prompt
      vars = {
        issue_title: @issue_title.presence || "N/A",
        issue_body: truncated_issue_body,
        agent_summary: @agent_summary.truncate(MAX_SUMMARY_INPUT, omission: "")
      }

      Prompts::Render.call(
        slug: PROMPT_SLUG,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      )
    end

    def truncated_issue_body
      return "N/A" if @issue_body.blank?

      @issue_body.truncate(MAX_ISSUE_BODY_INPUT, omission: "")
    end
  end
end
