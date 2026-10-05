# frozen_string_literal: true

require "json"

module Issues
  # Makes the semantic distinction between a delivered PR and a complete
  # source issue. Scheduling consumes only the durable result it records.
  # @spec AUTO-PICK-QUEUE-012
  class PartialCompletionAssessment
    include Llm::OutputNormalizer

    Result = Data.define(:partial, :reason)

    MODEL = "claude-haiku-4-5-20251001"
    TIMEOUT = 30
    PROMPT = <<~PROMPT
      Decide whether the source issue remains incomplete after its merged
      implementation pull request. Use only the supplied approved issue intent
      and authoritative unresolved prerequisites; do not infer from wording,
      checkboxes, or closing-reference syntax.

      Source issue: %{issue}
      Unresolved prerequisites: %{prerequisites}

      Return one JSON object: {"partial": boolean, "reason": string}.
      Set partial true only when the supplied evidence establishes remaining
      required work. Do not include markdown or extra keys.
    PROMPT

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      return unless issue.trusted?

      response = AgentHarness.send_message(
        format(PROMPT, issue: issue_context, prerequisites: prerequisite_context),
        provider: :claude, model: MODEL, timeout: TIMEOUT, tools: :none, **Llm::TextMode.options
      )
      return unless response.success?

      parse(response.output)
    rescue AgentHarness::Error, JSON::ParserError => e
      Rails.logger.warn(
        message: "partial_completion.assessment_failed",
        issue_id: issue.id,
        project_id: issue.project_id,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    private

    attr_reader :issue

    def parse(output)
      parsed = JSON.parse(strip_markdown_fence(output.to_s.strip))
      return unless parsed.is_a?(Hash) && [ true, false ].include?(parsed["partial"])

      reason = parsed["reason"].to_s.strip
      return if reason.blank?

      Result.new(partial: parsed["partial"], reason: reason)
    end

    def issue_context
      "##{issue.github_number} #{issue.title}\n#{issue.body.to_s.truncate(4000)}"
    end

    def prerequisite_context
      issue.blocking_issues.map { |blocker| "##{blocker.github_number} #{blocker.title}" }.join("\n")
    end
  end
end
