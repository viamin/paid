# frozen_string_literal: true

module Llm
  # Semantic boundary for a completed issue run that has no delivery artifact.
  class AssessNoOutputDisposition
    TIMEOUT = 60
    VALID_DISPOSITIONS = %w[recommend_close needs_input continue].freeze
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

    def self.valid_disposition?(result, continuation_authorized: false)
      result.is_a?(Hash) && result.keys.sort == %w[disposition next_action rationale] &&
        VALID_DISPOSITIONS.include?(result["disposition"]) &&
        (result["disposition"] != "continue" || continuation_authorized) &&
        %w[rationale next_action].all? { |key| result[key].is_a?(String) && result[key].strip.present? }
    end

    def initialize(agent_run:, diagnostic_output:, continuation_authorized: false, timeout: TIMEOUT)
      @agent_run = agent_run
      @diagnostic_output = diagnostic_output.to_s.truncate(20_000)
      @continuation_authorized = continuation_authorized == true
      @timeout = timeout
    end

    def call # @spec NO-OUTPUT-ISSUE-010 NO-OUTPUT-ISSUE-011
      assessment_response = response
      raise failure("unsuccessful_response") unless successful?(assessment_response)
      raise failure("invalid_disposition") unless assessment_response.respond_to?(:output)

      result = parse(assessment_response.output)
      raise failure("invalid_disposition") unless valid_disposition?(result)

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

    attr_reader :agent_run, :continuation_authorized, :diagnostic_output, :timeout

    def response
      Request.call(
        prompt: prompt,
        timeout: timeout,
        agent_run: agent_run,
        response_validator: method(:valid_response?)
      )
    end

    def parse(output)
      result = JSON.parse(output.to_s)
      raise failure("invalid_disposition") unless result.is_a?(Hash)

      result.deep_stringify_keys
    end

    def valid_response?(candidate)
      candidate.respond_to?(:output) && successful?(candidate) &&
        valid_disposition?(parse(candidate.output))
    rescue DispositionFailure, JSON::ParserError
      false
    end

    # Older supported response objects predate success?, and Llm::Request
    # intentionally treats those as transport-successful for compatibility.
    def successful?(candidate)
      !candidate.respond_to?(:success?) || candidate.success?
    end

    def valid_disposition?(result)
      self.class.valid_disposition?(result, continuation_authorized:)
    end

    def failure(category)
      DispositionFailure.new("No-output disposition assessment failed", category: category)
    end

    def prompt
      <<~PROMPT
        Assess the disposition of an issue-scoped coding run that produced no pull request or result commit.
        Decide semantic meaning from the issue scope and run output; do not infer resolution merely from a successful conversation.

        Existing coding continuation authority: #{continuation_authorized}.
        Return `continue` only when that value is true, the output identifies remaining in-scope work, and no human decision is missing. Return `needs_input` when a necessary approval or decision is missing. Return `recommend_close` only when the available evidence justifies recommending that a human close the source issue. Never grant implementation, continuation, merge, or budget authority.

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
