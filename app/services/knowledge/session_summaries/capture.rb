# frozen_string_literal: true

module Knowledge
  module SessionSummaries
    # Orchestrates session-summary capture for a completed agent run:
    # synthesizes structured observations via the LLM, persists them as an
    # AgentRunSessionSummary (an observation, not durable intent), tracks
    # token usage, and indexes the result into the knowledge-artifact
    # pipeline for search and future context bundles.
    #
    # @spec SESSION-SUMMARY-001
    # @spec SESSION-SUMMARY-002
    class Capture
      attr_reader :agent_run

      def initialize(agent_run:)
        @agent_run = agent_run
      end

      def self.call(...)
        new(...).call
      end

      def call
        existing = AgentRunSessionSummary.find_by(agent_run: agent_run)
        return existing if existing

        result = Llm::GenerateSessionSummary.call(agent_run: agent_run)
        return nil unless result

        summary = create_summary(result)
        track_tokens(result.response)
        record_llm_output_metric(summary)
        Knowledge::SessionSummaries::SyncKnowledgeArtifact.call(session_summary: summary)
        summary
      rescue ActiveRecord::RecordNotUnique
        AgentRunSessionSummary.find_by(agent_run: agent_run)
      end

      private

      def create_summary(result)
        AgentRunSessionSummary.create!(
          project: agent_run.project,
          agent_run: agent_run,
          issue: agent_run.issue,
          pull_request_number: agent_run.pull_request_number,
          pull_request_url: agent_run.pull_request_url,
          summary: result.summary,
          files_touched: result.files_touched,
          decisions: result.decisions,
          assumptions: result.assumptions,
          failures: result.failures,
          follow_ups: result.follow_ups,
          learnings: result.learnings,
          generated_at: Time.current
        )
      end

      def track_tokens(response)
        return unless response.respond_to?(:tokens) && response.tokens

        TokenUsageTracker.track(
          tracked_run: agent_run,
          usage: {
            tokens_input: response.respond_to?(:input_tokens) ? response.input_tokens.to_i : 0,
            tokens_output: response.respond_to?(:output_tokens) ? response.output_tokens.to_i : 0,
            llm_model: response.respond_to?(:model) ? response.model : nil,
            request_type: "agent",
            metadata: { operation: "session_summary" }
          },
          enforce_guardrails: false
        )
      end

      def record_llm_output_metric(summary)
        LlmOutputMetrics::Record.call(
          project: agent_run.project,
          output_type: "session_summary",
          prompt_slug: Llm::GenerateSessionSummary::PROMPT_SLUG,
          prompt_project: agent_run.project,
          source_type: "AgentRunSessionSummary",
          source_id: summary.id
        )
      rescue StandardError => e
        Rails.logger.warn(
          message: "llm_output_metrics.record_session_summary_failed",
          agent_run_session_summary_id: summary.id,
          error: e.message
        )
      end
    end
  end
end
