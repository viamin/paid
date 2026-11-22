# frozen_string_literal: true

module Llm
  # Semantic boundary for a completed issue run that has no delivery artifact.
  class AssessNoOutputDisposition
    TIMEOUT = 60
    VALID_DISPOSITIONS = %w[recommend_close needs_input].freeze
    RESPONSE_SCHEMA = {
      type: "object",
      properties: {
        disposition: { type: "string", enum: VALID_DISPOSITIONS },
        rationale: { type: "string" },
        next_action: { type: "string" }
      },
      required: %w[disposition rationale next_action],
      additionalProperties: false
    }.freeze

    class DispositionFailure < AgentHarness::Error
      attr_reader :diagnostic

      def initialize(message, **diagnostic)
        @diagnostic = diagnostic.freeze
        super(message)
      end
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, diagnostic_output:, timeout: TIMEOUT)
      @agent_run = agent_run
      @diagnostic_output = diagnostic_output.to_s.truncate(20_000)
      @timeout = timeout
    end

    def call # @spec NO-OUTPUT-ISSUE-010 NO-OUTPUT-ISSUE-011
      result = parse(response.output)
      raise failure("invalid_disposition") unless valid?(result)

      result
    rescue DispositionFailure
      raise
    rescue JSON::ParserError
      raise failure("invalid_json")
    rescue AgentHarness::TimeoutError
      raise failure("timeout")
    rescue AgentHarness::AuthenticationError
      raise failure("authentication_unavailable")
    rescue AgentHarness::ConfigurationError
      raise
    rescue AgentHarness::Error
      raise failure("transport_error")
    end

    private

    attr_reader :agent_run, :diagnostic_output, :timeout

    def response
      Llm::Request.call(prompt: prompt, timeout: timeout, agent_run: agent_run)
    end

    def parse(output)
      JSON.parse(output.to_s).deep_stringify_keys
    end

    def valid?(result)
      result.is_a?(Hash) && result.keys.sort == %w[disposition next_action rationale] &&
        VALID_DISPOSITIONS.include?(result["disposition"]) &&
        result["rationale"].to_s.strip.present? && result["next_action"].to_s.strip.present?
    end

    def failure(category)
      DispositionFailure.new("No-output disposition assessment failed", category: category)
    end

    def prompt
      <<~PROMPT
        Assess the disposition of an issue-scoped coding run that produced no pull request or result commit.
        Decide semantic meaning from the issue scope and run output; do not infer resolution merely from a successful conversation.

        Return `needs_input` when the output identifies remaining implementation, planning, a proposal, or a necessary approval/decision. Return `recommend_close` only when the available evidence justifies recommending that a human close the source issue. Never grant implementation, continuation, merge, or budget authority.

        Issue title: #{agent_run.issue&.title}
        Issue body: #{agent_run.issue&.body.to_s.truncate(10_000)}
        Run output:
        #{diagnostic_output}

        Return only a JSON object matching this schema:
        #{RESPONSE_SCHEMA.to_json}
      PROMPT
    end
  end
end
