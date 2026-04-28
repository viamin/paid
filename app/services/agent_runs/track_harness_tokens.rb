# frozen_string_literal: true

module AgentRuns
  class TrackHarnessTokens
    def initialize(agent_run:, response:, proxy_scope: nil)
      @agent_run = agent_run
      @response = response
      @proxy_scope = proxy_scope
    end

    def self.call(...)
      new(...).call
    end

    def call
      return unless response.respond_to?(:tokens) && response.tokens

      track_run_summary
      track_billable_delta
    end

    private

    attr_reader :agent_run, :response, :proxy_scope

    def track_run_summary
      TokenUsageTracker.track(
        agent_run: agent_run,
        usage: usage_payload(run_input, run_output, "run_summary"),
        update_aggregates: false
      )
    end

    def track_billable_delta
      delta_input = [ run_input - proxy_input, 0 ].max
      delta_output = [ run_output - proxy_output, 0 ].max
      return unless (delta_input + delta_output).positive?

      TokenUsageTracker.track(
        agent_run: agent_run,
        usage: usage_payload(delta_input, delta_output, "run_delta"),
        enforce_guardrails: false
      )
    end

    def proxy_totals
      @proxy_totals ||= effective_proxy_scope
        .where.not(request_type: %w[run_summary run_delta])
        .pick(Arel.sql("COALESCE(SUM(input_tokens), 0)"), Arel.sql("COALESCE(SUM(output_tokens), 0)")) || [ 0, 0 ]
    end

    def effective_proxy_scope
      proxy_scope || agent_run.token_usages
    end

    def proxy_input
      proxy_totals.first
    end

    def proxy_output
      proxy_totals.second
    end

    def usage_payload(tokens_input, tokens_output, request_type)
      {
        tokens_input: tokens_input,
        tokens_output: tokens_output,
        llm_model: llm_model_label,
        request_type: request_type
      }
    end

    # Falls back to the provider name when the harness response has no model
    # id — common for Claude Code runs where the CLI selects the model at
    # runtime rather than the runtime override pinning one.
    def llm_model_label
      response.model.presence || response.provider.to_s.presence
    end

    def run_input
      @run_input ||= response.input_tokens || 0
    end

    def run_output
      @run_output ||= response.output_tokens || 0
    end
  end
end
