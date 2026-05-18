# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::SecretsProxy" do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project) }
  let(:knowledge_run) { create(:knowledge_run, :running, project: project) }

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

  let(:google_response_body) do
    {
      candidates: [ { content: { parts: [ { text: "Hello!" } ] } } ],
      usageMetadata: { promptTokenCount: 80, candidatesTokenCount: 40, totalTokenCount: 120 },
      modelVersion: "gemini-2.0-flash"
    }.to_json
  end

  let(:knowledge_headers) do
    {
      "Content-Type" => "application/json",
      "X-Knowledge-Run-Id" => knowledge_run.id.to_s,
      "X-Proxy-Token" => knowledge_run.proxy_token
    }
  end

  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig)
      .with(:llm, :anthropic_api_key).and_return("sk-ant-test-key")
    allow(Rails.application.credentials).to receive(:dig)
      .with(:llm, :openai_api_key).and_return("sk-test-key")
    allow(Rails.application.credentials).to receive(:dig)
      .with(:llm, :google_api_key).and_return("google-test-key")
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

      it "uses the run owner's stored runner API key when a runner id header is present" do
        api_key = create(
          :provider_api_key,
          user: project.effective_owner,
          api_service_type: "anthropic",
          api_key: "sk-stored-anthropic-key"
        )
        runner = create(:runner, :api_key, user: project.effective_owner, runner_key: "claude", provider_api_key: api_key)

        post "/api/proxy/anthropic/v1/messages",
          params: { model: "claude-3-5-sonnet-20241022" }.to_json,
          headers: valid_headers.merge(
            "X-Paid-Provider-Id" => runner.id.to_s,
            "x-api-key" => "paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
          )

        expect(WebMock).to have_requested(:post, target_url)
          .with(headers: { "x-api-key" => "sk-stored-anthropic-key" })
      end

      it "uses a fallback-only runner API key when a runner id header is present" do
        runner = create_anthropic_api_key_provider(
          :rate_limit_fallback,
          api_key: "sk-fallback-anthropic-key",
          enabled_for_agent_runs: false,
          enabled_for_fallback: true
        )

        post "/api/proxy/anthropic/v1/messages",
          params: { model: "claude-3-5-sonnet-20241022" }.to_json,
          headers: valid_headers.merge(
            "X-Paid-Provider-Id" => runner.id.to_s,
            "x-api-key" => "paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
          )

        expect(WebMock).to have_requested(:post, target_url)
          .with(headers: { "x-api-key" => "sk-fallback-anthropic-key" })
      end

      it "rejects runner ids that are disabled for agent runs and fallback" do
        runner = create_anthropic_api_key_provider(
          enabled_for_agent_runs: false,
          enabled_for_fallback: false
        )

        post "/api/proxy/anthropic/v1/messages",
          params: { model: "claude-3-5-sonnet-20241022" }.to_json,
          headers: valid_headers.merge(
            "X-Paid-Provider-Id" => runner.id.to_s,
            "x-api-key" => "paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
          )

        expect(response).to have_http_status(:forbidden)
        expect(WebMock).not_to have_requested(:post, target_url)
      end

      it "rejects runner ids that are not available to the agent run owner" do
        other_user = create(:user)
        api_key = create(:provider_api_key, user: other_user, api_service_type: "anthropic")
        runner = create(:runner, :api_key, user: other_user, runner_key: "claude", provider_api_key: api_key)

        post "/api/proxy/anthropic/v1/messages",
          params: { model: "claude-3-5-sonnet-20241022" }.to_json,
          headers: valid_headers.merge(
            "X-Paid-Provider-Id" => runner.id.to_s,
            "x-api-key" => "paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
          )

        expect(response).to have_http_status(:forbidden)
        expect(WebMock).not_to have_requested(:post, target_url)
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

    context "with a knowledge run and a project owner API key" do
      let(:owner) { project.effective_owner }

      before do
        create(:provider_api_key, user: owner, api_service_type: "anthropic", api_key: "sk-owner-key")
        knowledge_run.update!(final_provider: "anthropic")
        allow(Rails.application.credentials).to receive(:dig)
          .with(:llm, :anthropic_api_key).and_return("sk-ant-test-key")
      end

      it "uses the owner's API key for the proxied request" do
        post "/api/proxy/anthropic/v1/messages",
          params: { model: "claude-3-5-sonnet-20241022" }.to_json,
          headers: knowledge_headers

        expect(response).to have_http_status(:ok)
        expect(WebMock).to have_requested(:post, target_url)
          .with(headers: { "x-api-key" => "sk-owner-key" })
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

    it "accepts knowledge-run authentication" do
      knowledge_run.update!(final_provider: "openai")

      post "/api/proxy/openai/v1/chat/completions",
        params: {}.to_json,
        headers: knowledge_headers

      expect(response).to have_http_status(:ok)
      expect(knowledge_run.reload.total_tokens).to eq(150)
      expect(TokenUsage.last.knowledge_run).to eq(knowledge_run)
    end

    it "uses the knowledge run owner's configured runner key when a knowledge runner header is present" do
      create(:provider_api_key, user: project.effective_owner, api_service_type: "openrouter", api_key: "sk-openrouter-old")
      latest_api_key = create(:provider_api_key, user: project.effective_owner, api_service_type: "openrouter", api_key: "sk-openrouter-new")
      knowledge_run.update!(provider_attempts: [ { "provider" => "openrouter", "attempted_at" => Time.current.iso8601 } ])

      openrouter_url = "https://openrouter.ai/api/v1/chat/completions"
      stub_request(:post, openrouter_url)
        .to_return(status: 200, body: openai_response_body, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/openai/v1/chat/completions",
        params: {}.to_json,
        headers: knowledge_headers.merge("X-Paid-Knowledge-Provider" => "openrouter")

      expect(response).to have_http_status(:ok)
      expect(WebMock).to have_requested(:post, openrouter_url)
        .with(headers: { "Authorization" => "Bearer #{latest_api_key.api_key}" })
    end

    it "preserves runner-specific versioned paths for OpenAI-compatible providers" do
      api_key = create(:provider_api_key, user: project.effective_owner, api_service_type: "zai", api_key: "sk-zai")
      knowledge_run.update!(provider_attempts: [ { "provider" => "zai", "attempted_at" => Time.current.iso8601 } ])

      zai_url = "https://api.z.ai/api/paas/v4/embeddings"
      stub_request(:post, zai_url)
        .to_return(status: 200, body: { data: [ { embedding: [ 0.1 ], index: 0 } ] }.to_json, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/openai/v1/embeddings",
        params: { input: [ "hello" ], model: "text-embedding-3-large", dimensions: 3072 }.to_json,
        headers: knowledge_headers.merge("X-Paid-Knowledge-Provider" => "zai")

      expect(response).to have_http_status(:ok)
      expect(WebMock).to have_requested(:post, zai_url)
        .with(headers: { "Authorization" => "Bearer #{api_key.api_key}" })
    end

    it "rejects knowledge runner headers outside the run's allowed providers" do
      create(:provider_api_key, user: project.effective_owner, api_service_type: "zai", api_key: "sk-zai")
      knowledge_run.update!(provider_attempts: [ { "provider" => "openrouter", "attempted_at" => Time.current.iso8601 } ])

      post "/api/proxy/openai/v1/chat/completions",
        params: {}.to_json,
        headers: knowledge_headers.merge("X-Paid-Knowledge-Provider" => "zai")

      expect(response).to have_http_status(:forbidden)
      expect(WebMock).not_to have_requested(:post, "https://api.z.ai/api/paas/v4/chat/completions")
    end

    it "uses the knowledge run final runner for the upstream base URL when the header is omitted" do
      api_key = create(:provider_api_key, user: project.effective_owner, api_service_type: "openrouter", api_key: "sk-openrouter")
      knowledge_run.update!(final_provider: "openrouter")

      openrouter_url = "https://openrouter.ai/api/v1/chat/completions"
      stub_request(:post, openrouter_url)
        .to_return(status: 200, body: openai_response_body, headers: { "Content-Type" => "application/json" })

      post "/api/proxy/openai/v1/chat/completions",
        params: {}.to_json,
        headers: knowledge_headers

      expect(response).to have_http_status(:ok)
      expect(WebMock).to have_requested(:post, openrouter_url)
        .with(headers: { "Authorization" => "Bearer #{api_key.api_key}" })
    end
  end

  describe "GET /api/proxy/openai/*path" do
    let(:target_url) { "https://api.openai.com/v1/models?limit=25&after=model_123" }

    before do
      stub_request(:get, target_url)
        .to_return(status: 200, body: { data: [ { id: "gpt-4o" } ] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "forwards auth, accept header, and query string to OpenAI" do
      get "/api/proxy/openai/v1/models?limit=25&after=model_123",
        headers: valid_headers.merge("Accept" => "application/json")

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("data" => [ { "id" => "gpt-4o" } ])
      expect(WebMock).to have_requested(:get, target_url)
        .with(headers: {
          "Authorization" => "Bearer sk-test-key",
          "Accept" => "application/json"
        })
    end
  end

  describe "POST /api/proxy/google/*path" do
    let(:target_url) { "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent" }

    before do
      stub_request(:post, target_url)
        .to_return(status: 200, body: google_response_body, headers: { "Content-Type" => "application/json" })
    end

    it "proxies the request to Google and returns the response" do
      post "/api/proxy/google/v1beta/models/gemini-2.0-flash:generateContent",
        params: { contents: [ { parts: [ { text: "Hello" } ] } ] }.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["usageMetadata"]).to be_present
    end

    it "injects the API key into the forwarded request" do
      post "/api/proxy/google/v1beta/models/gemini-2.0-flash:generateContent",
        params: {}.to_json,
        headers: valid_headers

      expect(WebMock).to have_requested(:post, target_url)
        .with(headers: { "x-goog-api-key" => "google-test-key" })
    end

    it "uses the run owner's stored runner API key when a runner id header is present" do
      api_key = create(
        :provider_api_key,
        user: project.effective_owner,
        api_service_type: "google",
        api_key: "stored-google-key"
      )
      runner = create(:runner, :api_key, user: project.effective_owner, runner_key: "gemini", provider_api_key: api_key)

      post "/api/proxy/google/v1beta/models/gemini-2.0-flash:generateContent",
        params: {}.to_json,
        headers: valid_headers.merge(
          "X-Paid-Provider-Id" => runner.id.to_s,
          "x-goog-api-key" => "paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
        )

      expect(WebMock).to have_requested(:post, target_url)
        .with(headers: { "x-goog-api-key" => "stored-google-key" })
    end

    it "tracks token usage with Google usageMetadata field names" do
      expect {
        post "/api/proxy/google/v1beta/models/gemini-2.0-flash:generateContent",
          params: {}.to_json,
          headers: valid_headers
      }.to change { agent_run.reload.tokens_input }.by(80)
        .and change { agent_run.reload.tokens_output }.by(40)
    end

    it "accepts embedded knowledge-run credentials in x-goog-api-key" do
      post "/api/proxy/google/v1beta/models/gemini-2.0-flash:generateContent",
        params: {}.to_json,
        headers: {
          "Content-Type" => "application/json",
          "x-goog-api-key" => "paid-knowledge-run:#{knowledge_run.id}:#{knowledge_run.proxy_token}"
        }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "query string forwarding" do
    let(:target_url_with_params) { "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse" }

    before do
      stub_request(:post, target_url_with_params)
        .to_return(status: 200, body: google_response_body, headers: { "Content-Type" => "application/json" })
    end

    it "preserves query string parameters when proxying" do
      post "/api/proxy/google/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse",
        params: {}.to_json,
        headers: valid_headers

      expect(response).to have_http_status(:ok)
      expect(WebMock).to have_requested(:post, target_url_with_params)
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
        expect(body["error"]).to eq("Missing agent run ID, knowledge run ID, or chat session ID")
      end
    end

    context "with embedded proxy credentials in Authorization" do
      before do
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(status: 200, body: openai_response_body, headers: { "Content-Type" => "application/json" })
      end

      it "authenticates the request" do
        post "/api/proxy/openai/v1/chat/completions",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
          }

        expect(response).to have_http_status(:ok)
      end

      it "authenticates knowledge-run requests" do
        post "/api/proxy/openai/v1/chat/completions",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer paid-knowledge-run:#{knowledge_run.id}:#{knowledge_run.proxy_token}"
          }

        expect(response).to have_http_status(:ok)
      end
    end

    context "with embedded proxy credentials in x-goog-api-key" do
      before do
        stub_request(:post, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent")
          .to_return(status: 200, body: google_response_body, headers: { "Content-Type" => "application/json" })
      end

      it "authenticates the request" do
        post "/api/proxy/google/v1beta/models/gemini-2.0-flash:generateContent",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "x-goog-api-key" => "paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
          }

        expect(response).to have_http_status(:ok)
      end
    end

    context "with embedded proxy credentials in x-api-key" do
      it "authenticates the request" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "x-api-key" => "paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
          }

        expect(response).to have_http_status(:ok)
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

    context "with finished agent run" do
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
    end

    context "with claimed agent run" do
      it "allows claimed runs (queued but claimed by a worker)" do
        claimed_run = create(:agent_run, project: project, status: "queued", temporal_workflow_id: "test-wf")

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Agent-Run-Id" => claimed_run.id.to_s,
            "X-Proxy-Token" => claimed_run.proxy_token
          }

        expect(response).to have_http_status(:ok)
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

    context "with completed knowledge run" do
      let(:knowledge_run) { create(:knowledge_run, :completed, project: project) }

      it "returns forbidden" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: knowledge_headers

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to eq("Invalid or inactive knowledge run")
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

    context "when UserSetting overrides max_tokens_per_run" do
      before do
        create(:user_setting,
          user: project.created_by,
          max_tokens_per_run: 5_000)
      end

      it "returns 429 when usage exceeds the custom limit" do
        agent_run.update!(tokens_input: 4_000, tokens_output: 2_000)

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:too_many_requests)
      end

      it "allows the request when usage is within the custom limit" do
        agent_run.update!(tokens_input: 1_000, tokens_output: 500)

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:ok)
      end
    end

    context "when the UserSetting still has the inherited global default" do
      before do
        project.update!(max_tokens_per_run: nil)
        project.account.update!(default_max_tokens_per_run: 6_000)
        project.created_by.settings
      end

      it "uses the account default for rate limiting" do
        agent_run.update!(tokens_input: 4_000, tokens_output: 2_000)

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:too_many_requests)
        expect(JSON.parse(response.body)["token_limit"]).to eq(6_000)
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

    context "when project has a custom max_tokens_per_run" do
      before do
        project.update!(max_tokens_per_run: 50_000)
      end

      it "returns 429 when usage exceeds the project limit" do
        agent_run.update!(tokens_input: 40_000, tokens_output: 20_000)

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:too_many_requests)
        body = JSON.parse(response.body)
        expect(body["token_limit"]).to eq(50_000)
      end

      it "marks the run exceeded when the proxy rejects at the hard limit" do
        agent_run.update!(tokens_input: 40_000, tokens_output: 20_000, token_limit_status: "ok")

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:too_many_requests)
        expect(agent_run.reload.token_limit_status).to eq("exceeded")
      end

      it "allows the request when within the project limit" do
        agent_run.update!(tokens_input: 10_000, tokens_output: 5_000)

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:ok)
      end

      it "returns 429 when usage equals the project limit" do
        agent_run.update!(tokens_input: 30_000, tokens_output: 20_000)

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:too_many_requests)
      end
    end

    context "when usage is near the warning threshold" do
      before do
        project.update!(max_tokens_per_run: 100_000, token_limit_warning_threshold: 80)
        agent_run.update!(tokens_input: 60_000, tokens_output: 25_000)
      end

      it "sets warning headers on the response" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: valid_headers

        expect(response).to have_http_status(:ok)
        expect(response.headers["X-Token-Limit-Warning"]).to eq("true")
        expect(response.headers["X-Token-Usage"]).to eq("85000")
        expect(response.headers["X-Token-Limit"]).to eq("100000")
      end
    end

    context "when a knowledge run exceeds its own limit" do
      let(:knowledge_run) { create(:knowledge_run, :running, project: project, total_tokens: 10_000, max_tokens: 10_000) }

      it "returns 429 and marks the knowledge run exceeded" do
        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: knowledge_headers

        expect(response).to have_http_status(:too_many_requests)
        expect(JSON.parse(response.body)["error"]).to eq("Token limit exceeded for this knowledge run")
        expect(knowledge_run.reload.token_limit_status).to eq("exceeded")
      end
    end

    context "when the request is authenticated as a projectless chat session" do
      it "proxies successfully without rate-limit warnings" do
        chat_session = create(:chat_session, account: project.account, project: nil)
        create(:token_usage, :chat, chat_session: chat_session, input_tokens: 1_000, output_tokens: 500)

        post "/api/proxy/anthropic/v1/messages",
          params: {}.to_json,
          headers: {
            "Content-Type" => "application/json",
            "X-Chat-Session-Id" => chat_session.id.to_s,
            "X-Proxy-Token" => chat_session.proxy_token
          }

        expect(response).to have_http_status(:ok)
        expect(response.headers).not_to have_key("X-Token-Limit-Warning")
      end
    end
  end

  def create_anthropic_api_key_provider(*traits, api_key: "sk-stored-anthropic-key", **attributes)
    provider_api_key = create(
      :provider_api_key,
      user: project.effective_owner,
      api_service_type: "anthropic",
      api_key: api_key
    )

    create(
      :runner,
      :api_key,
      *traits,
      user: project.effective_owner,
      runner_key: "claude",
      provider_api_key: provider_api_key,
      **attributes
    )
  end
end
