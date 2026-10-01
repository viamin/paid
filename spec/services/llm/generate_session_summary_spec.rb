# frozen_string_literal: true

require "rails_helper"

# @spec SESSION-SUMMARY-002
# @spec SESSION-SUMMARY-006
RSpec.describe Llm::GenerateSessionSummary do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:agent_run) { create(:agent_run, :completed, project: project, issue: issue) }

  let(:llm_json) do
    {
      summary: "Implemented rate limiting and added tests.",
      files_touched: %w[app/services/rate_limiter.rb spec/services/rate_limiter_spec.rb],
      decisions: [ "Used a sliding window instead of a token bucket." ],
      assumptions: [ "Assumed Redis is available." ],
      failures: [ "First attempt with an in-memory counter failed under concurrent requests." ],
      follow_ups: [ "Add a dashboard panel for rejections." ],
      learnings: [ "Rate limit config lives in config/rate_limits.yml." ]
    }.to_json
  end

  let(:parsed_payload) { JSON.parse(llm_json) }

  let(:legacy_response) do
    response = Object.new
    json = llm_json
    response.define_singleton_method(:output) { json }
    response.define_singleton_method(:success?) { true }
    response
  end

  before do
    allow(Llm::TextMode).to receive_messages(options: {}, enabled?: false)
    allow(AgentHarness).to receive(:send_message).and_return(legacy_response)
    agent_run.log!("stdout", "Implemented rate limiting for the public API.")
  end

  describe ".call" do
    it "returns nil when the agent run has no transcript" do
      empty_agent_run = create(:agent_run, :completed, project: project, issue: issue)

      expect(described_class.call(agent_run: empty_agent_run)).to be_nil
      expect(AgentHarness).not_to have_received(:send_message)
    end

    it "returns a populated result from the parsed LLM response" do
      result = described_class.call(agent_run: agent_run)

      expect(result.summary).to eq("Implemented rate limiting and added tests.")
      expect(result.files_touched).to eq(%w[app/services/rate_limiter.rb spec/services/rate_limiter_spec.rb])
      expect(result.decisions).to eq([ "Used a sliding window instead of a token bucket." ])
      expect(result.assumptions).to eq([ "Assumed Redis is available." ])
      expect(result.failures).to eq([ "First attempt with an in-memory counter failed under concurrent requests." ])
      expect(result.follow_ups).to eq([ "Add a dashboard panel for rejections." ])
      expect(result.learnings).to eq([ "Rate limit config lives in config/rate_limits.yml." ])
      expect(result.response).to eq(legacy_response)
    end

    context "when API-key authentication is configured" do
      let(:chat_transport) { instance_double(AgentHarness::Api::ChatTransport, call: schema_result) }

      let(:schema_result) do
        {
          status: :succeeded,
          content: llm_json,
          parsed: parsed_payload
        }
      end

      before do
        stub_const("ENV", ENV.to_hash.merge("ANTHROPIC_API_KEY" => "sk-ant-test-key"))
        allow(Llm::TextMode).to receive(:enabled?).and_return(true)
        allow(AgentHarness::Api::ChatTransport).to receive(:new).and_return(chat_transport)
      end

      it "routes through the schema-constrained ChatTransport and skips fence/quote cleanup" do
        described_class.call(agent_run: agent_run)

        expect(chat_transport).to have_received(:call) do |request|
          expect(request[:operation]).to eq(:schema)
          expect(request[:schema_name]).to eq("agent_run_session_summary")
          expect(request[:schema]).to eq(described_class::RESPONSE_SCHEMA)
          expect(request[:schema_mode]).to eq(:json_schema)
          expect(request[:timeout]).to eq(read_seconds: described_class::TIMEOUT)
          expect(request[:candidates].first).to include(
            provider: :anthropic,
            model: described_class::DEFAULT_MODEL,
            authentication_mode: :api_key
          )
        end
        expect(AgentHarness).not_to have_received(:send_message)
      end

      it "uses the schema-constrained parsed value as the result summary" do
        result = described_class.call(agent_run: agent_run)

        expect(result.summary).to eq("Implemented rate limiting and added tests.")
        expect(result.files_touched).to eq(%w[app/services/rate_limiter.rb spec/services/rate_limiter_spec.rb])
      end

      it "returns nil when the schema result is missing" do
        allow(chat_transport).to receive(:call).and_return(nil)

        expect(described_class.call(agent_run: agent_run)).to be_nil
      end

      it "returns nil when the schema result did not succeed" do
        allow(chat_transport).to receive(:call).and_return(status: :failed, parsed: nil, error: { code: :invalid_schema })

        expect(described_class.call(agent_run: agent_run)).to be_nil
      end

      it "returns nil when the schema result omits the required summary" do
        allow(chat_transport).to receive(:call).and_return(
          status: :succeeded,
          parsed: { "decisions" => [ "x" ] }
        )

        expect(described_class.call(agent_run: agent_run)).to be_nil
      end

      it "returns nil when no API key is configured despite text mode reporting enabled" do
        stub_const("ENV", ENV.to_hash.except("ANTHROPIC_API_KEY"))

        expect(described_class.call(agent_run: agent_run)).to be_nil
      end
    end

    it "returns nil when the provider call is unsuccessful" do
      allow(legacy_response).to receive(:success?).and_return(false)

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "returns nil when the response is not valid JSON" do
      allow(legacy_response).to receive(:output).and_return("not json")

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "returns nil when the parsed JSON has no summary" do
      allow(legacy_response).to receive(:output).and_return({ decisions: [ "x" ] }.to_json)

      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "strips a surrounding markdown fence before parsing" do
      allow(legacy_response).to receive(:output).and_return("```json\n#{llm_json}\n```")

      result = described_class.call(agent_run: agent_run)

      expect(result.summary).to eq("Implemented rate limiting and added tests.")
    end
  end

  describe "secret redaction" do
    it "redacts secrets in the transcript before sending it to the LLM" do
      leaky_agent_run = create(:agent_run, :completed, project: project, issue: issue)
      leaky_agent_run.log!("stdout", "Pushed with TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789 to origin.")

      described_class.call(agent_run: leaky_agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("[REDACTED").and(
          satisfy { |s| !s.include?("ghp_abcdefghijklmnopqrstuvwxyz0123456789") }
        ),
        hash_including(provider: :claude)
      )
    end

    it "redacts JWTs and strips NUL bytes in the transcript before sending it to the LLM" do
      leaky_agent_run = create(:agent_run, :completed, project: project, issue: issue)
      leaky_agent_run.log!("stdout", "jwt=eyJabc.eyJdef.ghiJKL\0 extra")

      described_class.call(agent_run: leaky_agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("[REDACTED").and(
          satisfy { |s| !s.include?("eyJabc.eyJdef.ghiJKL") && !s.include?("\x00") }
        ),
        hash_including(provider: :claude)
      )
    end

    it "redacts secrets in the issue title before sending it to the LLM" do
      leaky_issue = create(:issue, project: project, title: "Rotate TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789")
      leaky_agent_run = create(:agent_run, :completed, project: project, issue: leaky_issue)
      leaky_agent_run.log!("stdout", "Some work happened.")

      described_class.call(agent_run: leaky_agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("[REDACTED").and(
          satisfy { |s| !s.include?("ghp_abcdefghijklmnopqrstuvwxyz0123456789") }
        ),
        hash_including(provider: :claude)
      )
    end

    it "redacts secrets in the error message before sending it to the LLM" do
      leaky_agent_run = create(:agent_run, :completed, project: project, issue: issue,
        error_message: "Failed: TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789 unreachable")
      leaky_agent_run.log!("stdout", "Some work happened.")

      described_class.call(agent_run: leaky_agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("[REDACTED").and(
          satisfy { |s| !s.include?("ghp_abcdefghijklmnopqrstuvwxyz0123456789") }
        ),
        hash_including(provider: :claude)
      )
    end

    it "redacts secrets echoed back by the LLM into the parsed result" do
      leaky_json = {
        summary: "Committed a fix using jwt=eyJabc.eyJdef.ghiJKL.\u0000",
        files_touched: [], decisions: [], assumptions: [], failures: [], follow_ups: [], learnings: []
      }.to_json
      allow(legacy_response).to receive(:output).and_return(leaky_json)

      result = described_class.call(agent_run: agent_run)

      expect(result.summary).to include("[REDACTED")
      expect(result.summary).not_to include("eyJabc.eyJdef.ghiJKL")
      expect(result.summary).not_to include("\x00")
    end
  end
end
