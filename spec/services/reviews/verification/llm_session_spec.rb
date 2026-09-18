# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reviews::Verification::LlmSession do
  let(:operation) { "verified_review.find" }
  let(:error_class) { Class.new(StandardError) }
  let(:invalid_output_error) { Class.new(StandardError) }

  def harness_response(json, success: true, error: nil, input_tokens: 50, output_tokens: 25)
    instance_double(
      AgentHarness::Response,
      success?: success,
      output: json,
      error: error,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      model: "claude-sonnet-4-6"
    )
  end

  describe "#request_json" do
    it "parses JSON output and reports usage" do
      session = described_class.new(
        operation: operation, error_class: error_class,
        invalid_output_error: invalid_output_error,
        on_usage: ->(**usage) { @usage = usage }
      )
      allow(AgentHarness).to receive(:send_message).and_return(
        harness_response({ candidates: [ "ok" ] }.to_json)
      )

      result = session.request_json("prompt")

      expect(result).to eq("candidates" => [ "ok" ])
      expect(@usage).to include(
        tokens_input: 50, tokens_output: 25,
        llm_model: "claude-sonnet-4-6", operation: operation
      )
    end

    it "raises the configured error class when the harness reports failure" do
      session = described_class.new(
        operation: operation, error_class: error_class,
        invalid_output_error: invalid_output_error
      )
      allow(AgentHarness).to receive(:send_message).and_return(
        harness_response("", success: false, error: "provider down")
      )

      expect { session.request_json("prompt") }.to raise_error(error_class, /provider down/)
    end

    it "raises the invalid-output error when the payload is not an object" do
      session = described_class.new(
        operation: operation, error_class: error_class,
        invalid_output_error: invalid_output_error
      )
      allow(AgentHarness).to receive(:send_message).and_return(harness_response("[1,2,3]"))

      expect { session.request_json("prompt") }.to raise_error(invalid_output_error, /not a JSON object/)
    end

    # @spec REVIEW-VERIFY-009
    it "raises the invalid-output error without echoing the offending input on parse failure" do
      session = described_class.new(
        operation: operation, error_class: error_class,
        invalid_output_error: invalid_output_error
      )
      # Realistic LLM failure mode: the model returns prose that references a
      # file path and line number. JSON::ParserError#message embeds that
      # payload, so propagating it through `track_phase` would write it into
      # `agent_run_phases.metadata.error_message` — repository content in
      # the database, which violates REVIEW-VERIFY-009.
      offending = "I think app/services/foo.rb has a bug on line 7"
      allow(AgentHarness).to receive(:send_message).and_return(harness_response(offending))

      expect { session.request_json("prompt") }.to raise_error(invalid_output_error) do |error|
        expect(error.message).to eq("#{operation} output is not valid JSON")
        expect(error.message).not_to include("app/services/foo.rb")
        expect(error.message).not_to include("line 7")
      end
    end
  end
end
