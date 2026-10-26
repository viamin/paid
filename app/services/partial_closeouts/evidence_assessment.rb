# frozen_string_literal: true

module PartialCloseouts
  # Bounded semantic boundary for externally collected evidence. Structural
  # checks happen before this service; this service deliberately does not infer
  # sufficiency from a URL, a green run, or a report's existence.
  # @spec PARTIAL-CLOSEOUT-030
  class EvidenceAssessment
    MODEL = "claude-sonnet-4-6"
    TIMEOUT = 30

    def self.call(...) = new(...).call

    def initialize(submission:, notification:, prerequisite:, agent_harness: AgentHarness)
      @submission, @notification, @prerequisite, @agent_harness = submission, notification, prerequisite, agent_harness
    end

    def call
      return stale if revision_changed?

      response = agent_harness.send_message(prompt, provider: :claude, model: MODEL, timeout: TIMEOUT, tools: :none, **Llm::TextMode.options)
      return unavailable unless response.respond_to?(:success?) && response.success?

      parsed = JSON.parse(strip_markdown_fence(response.output.to_s)).deep_stringify_keys
      return unavailable unless valid?(parsed)

      parsed.merge("assessed_at" => Time.current.iso8601)
    rescue AgentHarness::Error, JSON::ParserError
      unavailable
    end

    private

    attr_reader :submission, :notification, :prerequisite, :agent_harness

    def revision_changed?
      current = Array(notification.metadata["prerequisites"]).find { |item| item["id"] == prerequisite["id"] }
      current.nil? || current["source_revision"] != submission["source_revision"] || current["intent_revision"] != submission["intent_revision"]
    end

    def valid?(value)
      value.is_a?(Hash) && %w[sufficient insufficient].include?(value["status"]) && value["reason"].is_a?(String) && value["reason"].strip.present?
    end

    def strip_markdown_fence(value)
      value.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
    end

    def stale = { "status" => "stale", "reason" => "The prerequisite changed after this evidence was collected.", "assessed_at" => Time.current.iso8601 }
    def unavailable = { "status" => "unavailable", "reason" => "Evidence could not be assessed; retry after the source is available.", "assessed_at" => Time.current.iso8601 }

    def prompt
      <<~PROMPT
        Assess whether submitted evidence satisfies exactly one partial-closeout prerequisite. Do not infer acceptance from a URL, a green run, a report, or a dismissal. Return JSON only with status (sufficient or insufficient) and a concise reason.
        Prerequisite: #{JSON.generate(prerequisite)}
        Submitted evidence: #{JSON.generate(submission.slice("evidence_type", "reference", "explanation", "provenance"))}
      PROMPT
    end
  end
end
