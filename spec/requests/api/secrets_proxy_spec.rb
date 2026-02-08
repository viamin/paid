# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::SecretsProxy" do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }

  let(:anthropic_response_body) do
    {
      id: "msg_123",
      type: "message",
      model: "claude-3-5-sonnet-20241022",
      usage: { input_tokens: 100, output_tokens: 50 },
      content: [ { type: "text", text: "Hello!" } ]
    }.to_json
  end

  let(:openai_response_body) do
    {
      id: "chatcmpl-123",
      model: "gpt-4o",
      usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
      choices: [ { message: { role: "assistant", content: "Hello!" } } ]
    }.to_json
  end

  let(:valid_headers) do
    {
      "Content-Type" => "application/json",
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.proxy_token
    }
  end

  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig)
      .with(:llm, :anthropic_api_key).and_return("sk-ant-test-key")
    allow(Rails.application.credentials).to receive(:dig)
      .with(:llm, :openai_api_key).and_return("sk-test-key")
  end

  describe "POST /api/proxy/anthropic/*path" do
    let(:target_url) { "https://api.anthropic.com/v1/messages" }

    before do
      stub_request(:post, target_url)
        .to_return(status: 200, body: anthropic_response_body, headers: { "Content-Type" => "application/json" })
    end

    context "with valid agent run" do
      it "proxies the request to Anthropic and returns the response" do
        post "/api/proxy/anthropic/v1/messages",
          params: { model: "claude-3-5-sonnet-20241022" }.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["model"]).to eq("claude-3-5-sonnet-20241022")
      end

      it "injects the API key into the forwarded request" do
        post "/api/proxy/anthropic/v1/messages",
          params: { model: "claude-3-5-sonnet-20241022" }.to_json,
          headers: valid_headers

        expect(WebMock).to have_requested(:post, target_url)
          .with(headers: { "x-api-key" => "sk-ant-test-key" })
      end

      it "forwards anthropic-version header when present" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers.merge("anthropic-version" => "2023-06-01")

        expect(WebMock).to have_requested(:post, target_url)
          .with(headers: { "anthropic-version" => "2023-06-01" })
      end

      it "forwards anthropic-beta header when present" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers.merge("anthropic-beta" => "messages-2024-12-19")

        expect(WebMock).to have_requested(:post, target_url)
          .with(headers: { "anthropic-beta" => "messages-2024-12-19" })
      end

      it "tracks token usage on the agent run" do
        expect {
          post "/api/proxy/anthropic/v1/messages",
            params: {}.to_json,
            headers: valid_headers
        }.to change { agent_run.reload.tokens_input }.by(100)
          .and change { agent_run.reload.tokens_output }.by(50)
      end

      it "tracks cost on the agent run" do
        # Use larger token counts to produce non-zero cost
        large_response = {
          id: "msg_123",
          model: "claude-3-5-sonnet-20241022",
          usage: { input_tokens: 100_000, output_tokens: 50_000 },
          content: [ { type: "text", text: "Hello!" } ]
        }.to_json

        stub_request(:post, target_url)
          .to_return(status: 200, body: large_response, headers: { "Content-Type" => "application/json" })

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        agent_run.reload
        expect(agent_run.cost_cents).to be > 0
      end

      it "updates project metrics" do
        expect {
          post "/api/proxy/anthropic/v1/messages",
            params: {}.to_json,
            headers: valid_headers
        }.to change { project.reload.total_tokens_used }.by(150)
      end

      it "creates an agent run log entry" do
        expect {
          post "/api/proxy/anthropic/v1/messages",
            params: {}.to_json,
            headers: valid_headers
        }.to change { agent_run.agent_run_logs.where(log_type: "metric").count }.by(1)
      end
    end

    context "when upstream returns an error" do
      before do
        stub_request(:post, target_url)
          .to_return(status: 500, body: { error: "Internal Server Error" }.to_json,
                     headers: { "Content-Type" => "application/json" })
      end

      it "returns the upstream error status" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:internal_server_error)
      end

      it "does not track usage on error responses" do
        expect {
          post "/api/proxy/anthropic/v1/messages",
            params: {}.to_json,
            headers: valid_headers
        }.not_to change { agent_run.reload.tokens_input }
      end
    end

    context "when upstream connection fails" do
      before do
        stub_request(:post, target_url).to_raise(Faraday::ConnectionFailed.new("Connection refused"))
      end

      it "returns bad gateway" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:bad_gateway)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("Upstream request failed")
      end
    end

    context "when API key is not configured" do
      before do
        allow(Rails.application.credentials).to receive(:dig)
          .with(:llm, :anthropic_api_key).and_return(nil)
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      end

      it "returns service unavailable" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:service_unavailable)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("not configured")
      end
    end
  end

  describe "POST /api/proxy/openai/*path" do
    let(:target_url) { "https://api.openai.com/v1/chat/completions" }

    before do
      stub_request(:post, target_url)
        .to_return(status: 200, body: openai_response_body, headers: { "Content-Type" => "application/json" })
    end

    it "proxies the request to OpenAI and returns the response" do
      post "/api/proxy/openai/v1/chat/completions",
        params: { model: "gpt-4o" }.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["model"]).to eq("gpt-4o")
    end

    it "injects the Bearer token into the forwarded request" do
      post "/api/proxy/openai/v1/chat/completions",
        params: {}.to_json,
        headers: valid_headers

      expect(WebMock).to have_requested(:post, target_url)
        .with(headers: { "Authorization" => "Bearer sk-test-key" })
    end

    it "tracks token usage with OpenAI field names" do
      expect {
        post "/api/proxy/openai/v1/chat/completions",
          params: {}.to_json,
          headers: valid_headers
      }.to change { agent_run.reload.tokens_input }.by(100)
        .and change { agent_run.reload.tokens_output }.by(50)
    end
  end

  describe "authentication" do
    before do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: anthropic_response_body, headers: { "Content-Type" => "application/json" })
    end

    context "without X-Agent-Run-Id header" do
      it "returns unauthorized" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: { "Content-Type" => "application/json" }

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("Missing agent run ID")
      end
    end

    context "with invalid agent run ID" do
      it "returns forbidden" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => "999999",
            "X-Proxy-Token" => "invalid"
          }

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("Invalid or inactive agent run")
      end
    end

    context "with non-running agent run" do
      let(:completed_run) { create(:agent_run, :completed, project: project) }

      it "returns forbidden for completed runs" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => completed_run.id.to_s,
            "X-Proxy-Token" => completed_run.proxy_token
          }

        expect(response).to have_http_status(:forbidden)
      end

      it "returns forbidden for pending runs" do
        pending_run = create(:agent_run, project: project, status: "pending")

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => pending_run.id.to_s,
            "X-Proxy-Token" => pending_run.proxy_token
          }

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "with invalid proxy token" do
      it "returns forbidden" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => agent_run.id.to_s,
            "X-Proxy-Token" => "invalid-token"
          }

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("Invalid proxy token")
      end
    end

    context "without proxy token" do
      it "returns forbidden without generating a token" do
        original_token = agent_run.proxy_token

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => agent_run.id.to_s
          }

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("Invalid proxy token")
        # Token should not have been regenerated for an unauthorized request
        expect(agent_run.reload.proxy_token).to eq(original_token)
      end
    end

    context "with nil proxy_token on agent run" do
      let(:agent_run) { create(:agent_run, :running, project: project) }

      it "lazily regenerates a proxy token and rejects the old token" do
        # Clear the token to simulate a pre-existing run
        token = agent_run.proxy_token
        agent_run.update_column(:proxy_token, nil)

        # Request with the old token should fail since a new one gets generated
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => agent_run.id.to_s,
            "X-Proxy-Token" => token
          }

        expect(response).to have_http_status(:forbidden)

        # The agent_run should now have a new proxy token persisted
        new_token = agent_run.reload.proxy_token
        expect(new_token).to be_present
        expect(new_token).not_to eq(token)
      end
    end
  end

  describe "rate limiting" do
    before do
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: anthropic_response_body, headers: { "Content-Type" => "application/json" })
    end

    context "when agent run exceeds token limit" do
      let(:agent_run) do
        create(:agent_run, :running, project: project,
          tokens_input: 9_000_000, tokens_output: 2_000_000)
      end

      it "returns too many requests" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:too_many_requests)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("Token limit exceeded for this agent run")
      end
    end

    context "when agent run is within token limit" do
      let(:agent_run) do
        create(:agent_run, :running, project: project,
          tokens_input: 1000, tokens_output: 500)
      end

      it "allows the request through" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
