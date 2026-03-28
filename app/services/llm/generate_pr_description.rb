# frozen_string_literal: true

module Llm
  # Generates a structured PR description from the agent's output and issue
  # context using agent_harness. The description leads with "why", summarizes
  # full scope, and surfaces design decisions — following the guidelines in
  # GitHub issue #581.
  #
  # Raises on LLM errors so the caller can log with full context (e.g.
  # agent_run_id, issue_number) and fall back to the raw agent summary.
  #
  # @example
  #   body = Llm::GeneratePrDescription.call(
  #     agent_summary: "Added auth middleware...",
  #     issue_title: "Add OAuth support",
  #     issue_body: "We need OAuth for..."
  #   )
  class GeneratePrDescription
    DEFAULT_MODEL = "claude-sonnet-4-6"
    MAX_DESCRIPTION_LENGTH = 50_000
    MAX_SUMMARY_INPUT = 20_000
    MAX_ISSUE_BODY_INPUT = 4000
    TIMEOUT = 30

    PROMPT_TEMPLATE = <<~PROMPT
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
      Title: %{issue_title}
      Body:
      %{issue_body}

      ## Agent Output
      %{agent_summary}
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
      response = AgentHarness.send_message(
        prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT
      )
      return nil unless response.success?

      response.output.presence
    end

    def prompt
      format(
        PROMPT_TEMPLATE,
        issue_title: @issue_title.presence || "N/A",
        issue_body: truncated_issue_body,
        agent_summary: @agent_summary.truncate(MAX_SUMMARY_INPUT, omission: "")
      )
    end

    def truncated_issue_body
      return "N/A" if @issue_body.blank?

      @issue_body.truncate(MAX_ISSUE_BODY_INPUT, omission: "")
    end
  end
end
