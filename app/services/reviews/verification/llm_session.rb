# frozen_string_literal: true

module Reviews
  module Verification
    # One structured-output LLM call for a verification pipeline stage.
    #
    # Every stage of the Find → Verify → Synthesize pipeline (#3898) needs the
    # same mechanics: send a prompt through +AgentHarness+ with tools disabled,
    # report token usage to the caller, and parse the reply as a JSON object.
    # Stages differ only in the error classes they surface, so the session is
    # constructed with those and stays free of stage semantics (ZFC: the
    # judgement lives in the prompt and reply, not here).
    #
    # Failures never degrade silently — an unsuccessful response or unparseable
    # output raises, so a broken stage can never turn into a clean review.
    class LlmSession
      include Llm::OutputNormalizer

      DEFAULT_MODEL = "claude-sonnet-4-6"
      TIMEOUT = 180

      # @param operation [String] usage label, e.g. +"verified_review.find"+
      # @param error_class [Class] raised when the harness reports failure
      # @param invalid_output_error [Class] raised when output is not a JSON object
      # @param on_usage [Proc, nil] receives
      #   +{ tokens_input:, tokens_output:, llm_model:, operation: }+ per call
      def initialize(operation:, error_class:, invalid_output_error:, on_usage: nil)
        @operation = operation
        @error_class = error_class
        @invalid_output_error = invalid_output_error
        @on_usage = on_usage
      end

      # @return [Hash] the parsed JSON object (string keys)
      def request_json(prompt)
        response = AgentHarness.send_message(prompt, **harness_options)
        raise @error_class, "#{@operation} LLM call failed: #{response.error}" unless response.success?

        report_usage(response)
        parse_object(response.output)
      end

      private

      def harness_options
        {
          provider: :claude,
          model: DEFAULT_MODEL,
          timeout: TIMEOUT,
          tools: :none,
          dangerous_mode: false,
          **Llm::TextMode.options
        }
      end

      def report_usage(response)
        return unless @on_usage

        @on_usage.call(
          tokens_input: response.input_tokens.to_i,
          tokens_output: response.output_tokens.to_i,
          llm_model: response.model,
          operation: @operation
        )
      end

      def parse_object(output)
        parsed = JSON.parse(strip_markdown_fence(output.to_s.strip))
        raise @invalid_output_error, "#{@operation} output is not a JSON object" unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        raise @invalid_output_error, "#{@operation} output is not valid JSON: #{e.message}"
      end
    end
  end
end
