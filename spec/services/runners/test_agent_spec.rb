# frozen_string_literal: true

require "rails_helper"
require "securerandom"

RSpec.describe Runners::TestAgent do
  # Clear provider API keys that control harness-vs-container path selection
  # so tests don't unexpectedly take the harness path when a developer has
  # these env vars set locally.
  around do |example|
    original_openai = ENV.delete("OPENAI_API_KEY")
    original_google = ENV.delete("GOOGLE_API_KEY")
    example.run
  ensure
    original_openai ? ENV["OPENAI_API_KEY"] = original_openai : ENV.delete("OPENAI_API_KEY")
    original_google ? ENV["GOOGLE_API_KEY"] = original_google : ENV.delete("GOOGLE_API_KEY")
  end

  let(:account) { create(:account, slug: "runners-test-agent-#{SecureRandom.hex(6)}") }
  let(:user) { create(:user, account: account, email: "runners-test-agent-#{SecureRandom.hex(6)}@example.com") }
  let(:github_token) { create(:github_token, account: account, created_by: user) }
  let!(:project) { create(:project, account: account, github_token: github_token, created_by: user) }
  let(:runner_record) { user.runners.find_or_create_by!(runner_key: "claude") }
  let(:test_run) do
    instance_double(
      AgentRun,
      id: 1,
      persisted?: true,
      destroy!: true
    )
  end
  let(:insert_result) { double(first: { "id" => 1 }) }

  def stub_insert_all
    allow(AgentRun).to receive(:insert_all!).and_return(insert_result)
    allow(AgentRun).to receive(:find).with(1).and_return(test_run)
  end

  def stub_proxy_api_key(provider_name, value)
    credentials = Rails.application.credentials
    allow(credentials).to receive(:dig).and_call_original
    allow(credentials).to receive(:dig).with(:llm, :"#{provider_name}_api_key").and_return(value)
  end

  def provider
    runner_record
  end

  # Stub the container path: provisions container, creates HarnessExecutor, calls check_runner
  def stub_container_smoke_test(harness_result)
    stub_insert_all
    allow(test_run).to receive(:with_container).and_yield(test_run)
    allow(AgentHarness).to receive(:check_provider).and_return(harness_result)
  end

  def decoded_kilocode_config(encoded_config)
    JSON.parse(Base64.strict_decode64(encoded_config))
  end

  def expected_anthropic_kilocode_config
    {
      "provider" => {
        "anthropic" => {
          "options" => {
            "apiKey" => "{env:ANTHROPIC_API_KEY}",
            "baseURL" => "https://api.anthropic.com"
          },
          "models" => {
            "claude-sonnet-4-20250514" => {
              "name" => "claude-sonnet-4-20250514",
              "id" => "claude-sonnet-4-20250514",
              "tool_call" => true
            }
          }
        }
      },
      "model" => "anthropic/claude-sonnet-4-20250514"
    }
  end

  describe ".call" do
    context "when claude smoke test succeeds via container" do
      let(:runner_record) { user.runners.find_or_create_by!(runner_key: "claude").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "claude")
        stub_container_smoke_test(
          name: :claude, status: "ok", message: "Smoke test passed", latency_ms: 42, error_category: nil, check: :smoke_test
        )
      end

      it "returns a successful result" do
        result = described_class.call(runner: provider)

        expect(result).to be_success
        expect(result.message).to eq("Agent is healthy")
        expect(result.error_type).to be_nil
      end

      it "delegates to AgentHarness.check_provider with a container executor" do
        described_class.call(runner: provider)

        expect(AgentHarness).to have_received(:check_provider).with(
          :claude,
          timeout: 60,
          executor: an_instance_of(Containers::HarnessExecutor),
          provider_runtime: an_instance_of(AgentHarness::ProviderRuntime)
        )
      end
    end

    context "when a provider returns the smoke-test success text with trailing punctuation" do
      let(:runner_record) { user.runners.find_or_create_by!(runner_key: "kilocode").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "kilocode")
        stub_container_smoke_test(
          name: :kilocode, status: "error", message: "OK.", output: "OK.",
          latency_ms: 10, error_category: nil, check: :smoke_test
        )
      end

      it "treats the result as a successful smoke test" do
        result = described_class.call(runner: provider)

        expect(result).to be_success
        expect(result.message).to eq("Agent is healthy")
      end
    end

    context "when claude returns an auth error via container smoke test" do
      let(:runner_record) { user.runners.find_or_create_by!(runner_key: "claude").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "claude")
        stub_container_smoke_test(
          name: :claude, status: "error", message: "No authentication token found",
          latency_ms: 10, error_category: :auth_expired, check: :smoke_test
        )
      end

      it "maps the harness error category to an authentication error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("No authentication token found")
      end
    end

    context "when claude returns a rate limit error via container smoke test" do
      let(:runner_record) { user.runners.find_or_create_by!(runner_key: "claude").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "claude")
        stub_container_smoke_test(
          name: :claude, status: "error", message: "Rate limit exceeded. Retry after 120",
          latency_ms: 10, error_category: :rate_limited, check: :smoke_test
        )
      end

      it "persists the provider rate limit state" do
        freeze_time do
          result = described_class.call(runner: provider)

          expect(result).not_to be_success
          expect(result.error_type).to eq(:rate_limited)

          provider_state = user.runner_states.find_by!(runner_name: "claude")
          expect(provider_state.rate_limited_until).to be_within(1.second).of(120.seconds.from_now)
        end
      end
    end

    context "when claude returns a capacity-exhausted message" do
      let(:runner_record) { user.runners.find_or_create_by!(runner_key: "claude").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "claude")
        stub_container_smoke_test(
          name: :claude, status: "error",
          message: "You have exhausted your capacity on this model.",
          latency_ms: 10, error_category: :rate_limited, check: :smoke_test
        )
      end

      it "classifies the result as rate limited and persists provider state" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:rate_limited)
        expect(user.runner_states.find_by!(runner_name: "claude")).to be_rate_limited
      end
    end

    context "when claude returns the current subscription limit wording" do
      let(:runner_record) { user.runners.find_or_create_by!(runner_key: "claude").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "claude")
        stub_container_smoke_test(
          name: :claude, status: "error",
          message: "You've hit your limit · resets Apr 6, 10pm (UTC)",
          latency_ms: 10, error_category: :rate_limited, check: :smoke_test
        )
      end

      it "classifies the result as rate limited and parses the reset time" do
        travel_to Time.utc(2026, 4, 5, 12, 0, 0) do
          result = described_class.call(runner: provider)

          expect(result).not_to be_success
          expect(result.error_type).to eq(:rate_limited)

          provider_state = user.runner_states.find_by!(runner_name: "claude")
          expect(provider_state.rate_limited_until).to eq(Time.utc(2026, 4, 6, 22, 0, 0))
        end
      end
    end

    context "when codex has a Paid-managed OpenAI API key configured" do
      let(:api_key_record) { create(:runner_api_key, user: user, api_service_type: "openai") }
      let(:runner_record) { create(:runner, :api_key, user: user, runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false, provider_api_key: api_key_record) }
      let(:health_result) { { name: :codex, status: "ok", message: "All checks passed", latency_ms: 12 } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "codex")
        stub_proxy_api_key(:openai, "sk-test-key")
        allow(AgentHarness).to receive(:check_provider).and_return(health_result)
      end

      it "uses agent-harness for the health check" do
        result = described_class.call(runner: provider)

        expect(result).to be_success
        expect(AgentHarness).to have_received(:check_provider).with(:codex, timeout: 60)
      end
    end

    context "when agent-harness returns a binary-encoded failure message" do
      let(:api_key_record) { create(:runner_api_key, user: user, api_service_type: "openai") }
      let(:runner_record) { create(:runner, :api_key, user: user, runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false, provider_api_key: api_key_record) }
      let(:health_result) { { name: :codex, status: "error", message: "bad \xFF auth\x00".b, latency_ms: 12 } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "codex")
        stub_proxy_api_key(:openai, "sk-test-key")
        allow(AgentHarness).to receive(:check_provider).and_return(health_result)
      end

      it "normalizes the message before classification and response" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("bad \uFFFD auth")
      end
    end

    context "when agent-harness returns valid UTF-8 bytes tagged as binary" do
      let(:api_key_record) { create(:runner_api_key, user: user, api_service_type: "openai") }
      let(:runner_record) { create(:runner, :api_key, user: user, runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false, provider_api_key: api_key_record) }
      let(:health_result) { { name: :codex, status: "error", message: "caf\xC3\xA9 auth".b, latency_ms: 12 } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "codex")
        stub_proxy_api_key(:openai, "sk-test-key")
        allow(AgentHarness).to receive(:check_provider).and_return(health_result)
      end

      it "preserves the original UTF-8 text before classifying the failure" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("café auth")
      end
    end

    context "when a stale codex provider state exists and a harness health check succeeds" do
      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "codex")
        stub_proxy_api_key(:openai, "sk-test-key")
        allow(AgentHarness).to receive(:check_provider).and_return(name: :codex, status: "ok", message: "All checks passed", latency_ms: 12)
      end

      it "clears the stale provider state" do
        codex_provider = create(:runner, :api_key, user: user, runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false, provider_api_key: create(:runner_api_key, user: user, api_service_type: "openai"))
        provider_state = create(
          :provider_state,
          :rate_limited,
          :circuit_half_open,
          user: user,
          runner_name: codex_provider.state_key
        )

        result = described_class.call(runner: codex_provider)

        expect(result).to be_success

        provider_state.reload
        expect(provider_state.failure_count).to eq(0)
        expect(provider_state.circuit_state).to eq("closed")
        expect(provider_state.circuit_opened_at).to be_nil
        expect(provider_state.rate_limited_until).to be_nil
      end
    end

    context "when codex returns a rate limit error from the harness path" do
      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "codex")
        stub_proxy_api_key(:openai, "sk-test-key")
      end

      it "persists the provider rate limit state using the absolute reset timestamp" do
        travel_to Time.utc(2026, 4, 5, 12, 0, 0) do
          codex_provider = create(:runner, :api_key, user: user, runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false, provider_api_key: create(:runner_api_key, user: user, api_service_type: "openai"))
          reset_at = Time.utc(2026, 4, 6, 10, 0, 0)
          allow(AgentHarness).to receive(:check_provider).and_return(
            name: :codex,
            status: "error",
            message: "Rate limit exceeded. Reset at: #{reset_at.to_i}",
            latency_ms: 12
          )

          result = described_class.call(runner: codex_provider)

          expect(result).not_to be_success
          expect(result.error_type).to eq(:rate_limited)

          provider_state = user.runner_states.find_by!(runner_name: codex_provider.state_key)
          expect(provider_state.rate_limited_until).to eq(reset_at)
        end
      end
    end

    context "when gemini has a Paid-managed Google API key configured" do
      let(:runner_record) { create(:runner, :api_key, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false, provider_api_key: create(:runner_api_key, user: user, api_service_type: "google")) }
      let(:health_result) { { name: :gemini, status: "ok", message: "All checks passed", latency_ms: 12 } }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_proxy_api_key(:google, "AIza-test-key")
        allow(AgentHarness).to receive(:check_provider).and_return(health_result)
      end

      it "uses agent-harness for the health check" do
        result = described_class.call(runner: provider)

        expect(result).to be_success
        expect(AgentHarness).to have_received(:check_provider).with(:gemini, timeout: 60)
      end
    end

    context "when codex smoke test succeeds via container" do
      let(:runner_record) { create(:runner, user: user, runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "codex")
        stub_container_smoke_test(
          name: :codex, status: "ok", message: "Smoke test passed", latency_ms: 30, error_category: nil, check: :smoke_test
        )
      end

      it "delegates to the harness smoke test contract" do
        described_class.call(runner: provider)

        expect(AgentHarness).to have_received(:check_provider).with(
          :codex,
          timeout: 60,
          executor: an_instance_of(Containers::HarnessExecutor),
          provider_runtime: an_instance_of(AgentHarness::ProviderRuntime)
        )
      end
    end

    context "when a stale codex provider state exists and the container test succeeds" do
      let(:runner_record) { create(:runner, user: user, runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let!(:provider_state) do
        create(
          :provider_state,
          :rate_limited,
          :circuit_half_open,
          user: user,
          runner_name: "codex"
        )
      end

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "codex")
        stub_container_smoke_test(
          name: :codex, status: "ok", message: "Smoke test passed", latency_ms: 30, error_category: nil, check: :smoke_test
        )
      end

      it "clears the stale provider state" do
        result = described_class.call(runner: provider)

        expect(result).to be_success

        provider_state.reload
        expect(provider_state.failure_count).to eq(0)
        expect(provider_state.circuit_state).to eq("closed")
        expect(provider_state.circuit_opened_at).to be_nil
        expect(provider_state.rate_limited_until).to be_nil
      end
    end

    context "when gemini smoke test fails via container with auth error" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_container_smoke_test(
          name: :gemini, status: "error",
          message: "Please set an Auth method in your /home/agent/.gemini/settings.json or specify one of the following environment variables before running: GEMINI_API_KEY, GOOGLE_GENAI_USE_VERTEXAI, GOOGLE_GENAI_USE_GCA",
          latency_ms: 10, error_category: :auth_expired, check: :smoke_test
        )
      end

      it "returns an authentication error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to include("Please set an Auth method")
      end
    end

    context "when gemini returns a validation-required error" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_container_smoke_test(
          name: :gemini, status: "error",
          message: "Verify your account to continue.",
          latency_ms: 10, error_category: :auth_expired, check: :smoke_test
        )
      end

      it "returns a concise authentication error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Verify your account to continue.")
      end
    end

    context "when gemini hits the proxy without a configured upstream key" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_container_smoke_test(
          name: :gemini, status: "error",
          message: "[API Error: {\"error\":\"API key not configured for google\"}]",
          latency_ms: 10, error_category: :authentication, check: :smoke_test
        )
      end

      it "returns a concise authentication error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Paid is not configured with a Google API key for containerized Gemini runs.")
      end
    end

    context "when codex cannot authenticate to the Paid proxy" do
      let(:runner_record) { create(:runner, user: user, runner_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "codex")
        stub_container_smoke_test(
          name: :codex, status: "error",
          message: "Unauthorized: {\"error\":\"Missing agent run ID\"}, url: http://web:3000/api/proxy/openai/responses",
          latency_ms: 10, error_category: :auth_expired, check: :smoke_test
        )
      end

      it "returns a concise authentication error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Codex did not forward the Paid container credentials to the OpenAI proxy.")
      end
    end

    context "when opencode emits ansi noise before an auth failure" do
      let(:runner_record) { create(:runner, user: user, runner_key: "opencode", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "opencode")
        stub_container_smoke_test(
          name: :opencode, status: "error",
          message: "\e[0m▄\e[0m\n[API Error: {\"error\":\"API key not configured for openai\"}]",
          latency_ms: 10, error_category: :auth_expired, check: :smoke_test
        )
      end

      it "returns the translated auth error instead of ansi noise" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Paid is not configured with an OpenAI API key for containerized OpenAI-backed runs (Codex or OpenCode).")
      end
    end

    context "when copilot is missing from an outdated agent image" do
      let(:runner_record) { create(:runner, user: user, runner_key: "copilot", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "github_copilot")
        stub_container_smoke_test(
          name: :github_copilot, status: "error",
          message: 'OCI runtime exec failed: exec failed: unable to start container process: exec: "copilot": executable file not found in $PATH',
          latency_ms: 10, error_category: :installation, check: :smoke_test
        )
      end

      it "returns a concise installation error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:installation)
        expect(result.message).to eq("GitHub Copilot CLI is missing from the agent container. Rebuild the paid-agent image to install the fixed Copilot CLI package.")
      end
    end

    context "when copilot outputs only MCP session events without a response" do
      let(:runner_record) { create(:runner, user: user, runner_key: "copilot", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      let(:mcp_event) do
        '{"type":"session.mcp_server_status_changed","data":{"serverName":"github-mcp-server","status":"connected"},"id":"853d58f1-3fe9-4407-9c7d-1807e033877e","timestamp":"2026-05-10T19:15:23.221Z","parentId":"3ef4d1aa-ac74-4058-854a-ac70cfd40c09","ephemeral":true}'
      end

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "github_copilot")
        stub_container_smoke_test(
          name: :github_copilot, status: "error",
          message: mcp_event,
          latency_ms: 2000, error_category: nil, check: :smoke_test
        )
      end

      it "returns a user-friendly message instead of raw MCP JSON" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to eq("Agent started but did not produce a response. Verify the runner credentials and connectivity.")
      end

      it "handles multiple MCP session events" do
        shutdown_event = '{"type":"session.shutdown","data":{},"id":"abc123"}'
        multi_mcp = "#{mcp_event}\n#{shutdown_event}"
        allow(AgentHarness).to receive(:check_provider).and_return(
          { name: :github_copilot, status: "error", message: multi_mcp, latency_ms: 3000, error_category: nil, check: :smoke_test }
        )

        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.message).to eq("Agent started but did not produce a response. Verify the runner credentials and connectivity.")
      end

      it "handles the session.mcp_servers_loaded variant" do
        # Regression coverage: the noisy-line filter originally listed
        # mcp_server_status_changed and shutdown by name, missing the
        # session.mcp_servers_loaded event that the Copilot CLI also emits.
        loaded_event = '{"type":"session.mcp_servers_loaded","data":{"servers":[{"name":"github-mcp-server","status":"connected","source":"builtin"}]},"id":"d4176d87-aafc-4d86-a9e9-d1db197b412a","timestamp":"2026-05-11T14:19:47.044Z","parentId":"c9377b33-23f7-4c06-9aad-f2708d7d15b2","ephemeral":true}'
        allow(AgentHarness).to receive(:check_provider).and_return(
          { name: :github_copilot, status: "error", message: loaded_event, latency_ms: 3000, error_category: nil, check: :smoke_test }
        )

        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.message).to eq("Agent started but did not produce a response. Verify the runner credentials and connectivity.")
      end
    end

    context "when opencode smoke test succeeds via container" do
      let(:runner_record) { create(:runner, user: user, runner_key: "opencode", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "opencode")
        stub_container_smoke_test(
          name: :opencode, status: "ok", message: "Smoke test passed", latency_ms: 30, error_category: nil, check: :smoke_test
        )
      end

      it "delegates to the harness smoke test" do
        result = described_class.call(runner: provider)

        expect(result).to be_success
        expect(AgentHarness).to have_received(:check_provider).with(
          :opencode,
          timeout: 60,
          executor: an_instance_of(Containers::HarnessExecutor),
          provider_runtime: nil
        )
      end
    end

    context "when direct-outbound opencode is tested" do
      let(:api_key) { create(:runner_api_key, user: user, api_service_type: "openrouter") }
      let(:runner_record) do
        create(
          :provider,
          user: user,
          runner_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          enabled_for_agent_runs: false,
          enabled_for_fallback: false,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
        )
      end

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "opencode")
        stub_container_smoke_test(
          name: :opencode, status: "ok", message: "Smoke test passed", latency_ms: 30, error_category: nil, check: :smoke_test
        )
      end

      it "passes the provider runtime to the harness check" do
        described_class.call(runner: provider)

        expect(AgentHarness).to have_received(:check_provider).with(
          :opencode,
          timeout: 60,
          executor: an_instance_of(Containers::HarnessExecutor),
          provider_runtime: an_instance_of(AgentHarness::ProviderRuntime)
        )
      end

      it "only clears the routing-key state for api-key entries" do
        routing_state = create(:runner_state, user: user, runner_name: provider.state_key, failure_count: 2)
        provider_key_state = create(:runner_state, user: user, runner_name: provider.runner_key, failure_count: 3)

        described_class.call(runner: provider)

        expect(routing_state.reload.failure_count).to eq(0)
        expect(provider_key_state.reload.failure_count).to eq(3)
      end
    end

    context "when direct-outbound kilocode is tested" do
      let(:api_key) { create(:runner_api_key, user: user, api_service_type: "anthropic") }
      let(:runner_record) do
        create(
          :provider,
          user: user,
          runner_key: "kilocode",
          auth_type: "api_key",
          provider_api_key: api_key,
          enabled_for_agent_runs: false,
          enabled_for_fallback: false,
          config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-20250514" } }
        )
      end

      let(:prep_result) do
        Containers::Provision::Result.success(stdout: "", stderr: "", exit_code: 0)
      end

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "kilocode")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
        allow(test_run).to receive(:execute_in_container).and_return(prep_result)
        allow(AgentHarness).to receive(:check_provider).and_return(
          name: :kilocode, status: "ok", message: "Smoke test passed", latency_ms: 30, error_category: nil, check: :smoke_test
        )
      end

      it "passes a provider runtime with the upstream API key" do
        described_class.call(runner: provider)

        expect(AgentHarness).to have_received(:check_provider).with(
          :kilocode,
          timeout: 60,
          executor: an_instance_of(Containers::HarnessExecutor),
          provider_runtime: an_instance_of(AgentHarness::ProviderRuntime)
        )
      end

      it "materializes the kilocode config file before the smoke test" do
        described_class.call(runner: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          [ "sh", "-c", a_string_including("mkdir -p /home/agent/.config/kilo") ],
          hash_including(timeout: 30, env: hash_including("KILOCODE_CONFIG_B64"))
        )
      end

      it "generates a v7.1.3-compatible config with provider as a record" do
        captured_env = nil
        allow(test_run).to receive(:execute_in_container) do |cmd, **kwargs|
          captured_env = kwargs[:env] if cmd.is_a?(Array) && cmd.join.include?("config.json")
          prep_result
        end

        described_class.call(runner: provider)

        expect(captured_env).to include("KILOCODE_CONFIG_B64")
        expect(decoded_kilocode_config(captured_env["KILOCODE_CONFIG_B64"])).to eq(expected_anthropic_kilocode_config)
      end
    end

    context "when the provider reports a rate limit via container smoke test" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_container_smoke_test(
          name: :gemini, status: "error",
          message: "You're out of extra usage · resets 8am (UTC)",
          latency_ms: 10, error_category: :rate_limited, check: :smoke_test
        )
      end

      it "returns a rate limited error with the provider message" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:rate_limited)
        expect(result.message).to eq("You're out of extra usage · resets 8am (UTC)")
      end
    end

    context "when the harness returns a binary encoded rate limit message" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_container_smoke_test(
          name: :gemini, status: "error",
          message: "You're out of extra usage \xB7 resets 8am (UTC)\x00\n".b,
          latency_ms: 10, error_category: :rate_limited, check: :smoke_test
        )
      end

      it "normalizes the output before classification" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:rate_limited)
        expect(result.message).to eq("You're out of extra usage � resets 8am (UTC)")
      end
    end

    context "when container provisioning surfaces an authentication-style message" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container)
          .and_raise(Containers::Provision::ProvisionError, "Invalid API key")
      end

      it "returns a connection error because provision failures are infrastructure errors" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:connection)
        expect(result.message).to eq("Invalid API key")
      end
    end

    context "when the harness returns a binary encoded error message" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_container_smoke_test(
          name: :gemini, status: "error",
          message: "Invalid API key \xFF\x00".b,
          latency_ms: 10, error_category: :auth_expired, check: :smoke_test
        )
      end

      it "normalizes the message before classification" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Invalid API key �")
      end
    end

    context "when the agent times out" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container)
          .and_raise(Containers::Provision::TimeoutError, "Timed out after 30s")
      end

      it "returns a timeout error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:timeout)
        expect(result.message).to eq("Timed out after 30s")
      end
    end

    context "when a generic container error occurs" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container)
          .and_raise(Containers::Provision::ProvisionError, "Connection refused")
      end

      it "returns a connection error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:connection)
        expect(result.message).to eq("Connection refused")
      end
    end

    context "when a generic container error message is binary encoded" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container)
          .and_raise(Containers::Provision::ProvisionError, "Connection refused \xFF\x00".b)
      end

      it "normalizes the rescued exception message" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:connection)
        expect(result.message).to eq("Connection refused �")
      end
    end

    context "when the provider is unsupported" do
      before do
        allow(RunnerSupport).to receive(:supported_runner_key?).and_return(false)
      end

      it "returns an unexpected error indicating the provider is unrecognized" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to include("not recognized by the agent harness")
      end
    end

    context "when the provider is supported but not container-executable" do
      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: false)
      end

      it "returns an installation error indicating the CLI is not installed" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:installation)
        expect(result.message).to include("CLI is not installed in the agent container")
      end
    end

    context "when the user has no project context for a containerized test" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        project.destroy!
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
      end

      it "returns a helpful error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to eq("Add a project before testing runners in the agent container")
      end
    end

    context "when an unexpected error occurs" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        allow(AgentRun).to receive(:insert_all!)
          .and_raise(RuntimeError, "Something went wrong")
      end

      it "returns an unexpected error" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to eq("Something went wrong")
      end
    end

    context "when an unexpected error message is binary encoded" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        allow(AgentRun).to receive(:insert_all!)
          .and_raise(RuntimeError, "Something went wrong \xFF\x00".b)
      end

      it "normalizes the rescued exception message" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to eq("Something went wrong �")
      end
    end

    context "when the harness error_category maps to a known error type" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
      end

      it "prefers the harness-classified error category over pattern matching" do
        stub_container_smoke_test(
          name: :gemini, status: "error",
          message: "Rate limit exceeded. Retry after 60",
          latency_ms: 10, error_category: :rate_limited, check: :smoke_test
        )

        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:rate_limited)
      end
    end

    context "when the harness marks a noisy provider failure as rate limited" do
      let(:runner_record) { create(:runner, user: user, runner_key: "kilocode", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "kilocode")
        stub_container_smoke_test(
          name: :kilocode,
          status: "error",
          message: "Performing one time database migration, may take a few minutes...\nModel not found: openai/glm-5.1.",
          latency_ms: 10,
          error_category: :rate_limited,
          check: :smoke_test
        )
      end

      it "uses the extracted provider failure instead of the noisy rate-limit classification" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to eq("Model not found: openai/glm-5.1.")
      end
    end

    context "when the harness returns a generic failure without error_category" do
      let(:runner_record) { create(:runner, user: user, runner_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(RunnerSupport).to receive_messages(supported_runner_key?: true,
          container_executable_runner_key?: true, harness_runner_key_for: "gemini")
        stub_container_smoke_test(
          name: :gemini, status: "error",
          message: "Process exited abnormally",
          latency_ms: 10, error_category: nil, check: :smoke_test
        )
      end

      it "falls back to pattern-based classification" do
        result = described_class.call(runner: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to include("Process exited abnormally")
      end
    end
  end

  describe "token and auth pattern classification via .call" do
    let(:runner_record) { user.runners.find_or_create_by!(runner_key: "claude").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }

    before do
      allow(RunnerSupport).to receive_messages(
        supported_runner_key?: true,
        container_executable_runner_key?: true,
        harness_runner_key_for: "claude"
      )
    end

    def call_with_message(message)
      stub_container_smoke_test(
        name: :claude, status: "error", message: message,
        latency_ms: 10, error_category: nil, check: :smoke_test
      )
      described_class.call(runner: provider)
    end

    it "does not misclassify 'unexpected token' JSON parse errors as authentication" do
      result = call_with_message("SyntaxError: unexpected token '<' at position 0")
      expect(result.error_type).not_to eq(:authentication)
    end

    it "does not misclassify 'CSRF token mismatch' as authentication" do
      result = call_with_message("CSRF token mismatch")
      expect(result.error_type).not_to eq(:authentication)
    end

    it "does not misclassify 'unexpected token in JSON' as authentication" do
      result = call_with_message("JSON.parse: unexpected token at line 1 column 1")
      expect(result.error_type).not_to eq(:authentication)
    end

    it "does not misclassify 'Invalid authenticity token' as authentication" do
      result = call_with_message("ActionController::InvalidAuthenticityToken: Invalid authenticity token")
      expect(result.error_type).not_to eq(:authentication)
    end

    it "does not misclassify 'authorization failed' as authentication" do
      result = call_with_message("authorization failed: insufficient permissions")
      expect(result.error_type).not_to eq(:authentication)
    end

    it "correctly classifies a real token expiration as authentication" do
      result = call_with_message("token expired")
      expect(result.error_type).to eq(:authentication)
    end

    it "correctly classifies 'invalid token' as authentication" do
      result = call_with_message("invalid token")
      expect(result.error_type).to eq(:authentication)
    end

    it "correctly classifies 'revoked token' as authentication" do
      result = call_with_message("revoked token")
      expect(result.error_type).to eq(:authentication)
    end
  end

  describe "smoke test timeout forwarding (issue #1538)" do
    let(:provider_class) do
      Class.new(AgentHarness::Providers::Base) do
        class << self
          attr_accessor :contract_timeout, :provider_instance

          def provider_name
            :kilocode
          end

          def binary_name
            "kilo"
          end

          def available?
            true
          end

          def smoke_test_contract
            {
              prompt: "Reply with exactly OK.",
              timeout: contract_timeout,
              expected_output: "OK",
              require_output: true
            }
          end

          private

          def build_provider_instance(config:, executor:, logger:)
            provider_instance || new(config: config, executor: executor, logger: logger)
          end
        end

        attr_reader :received_smoke_test_timeout, :received_provider_runtime

        def validate_config
          { valid: true, errors: [] }
        end

        def smoke_test(timeout:, provider_runtime:)
          @received_smoke_test_timeout = timeout
          @received_provider_runtime = provider_runtime
          { ok: true, status: "ok", message: "Smoke test passed" }
        end
      end
    end

    def run_health_check(provider_instance:, contract_timeout:, caller_timeout:)
      allow(AgentHarness::Providers::Registry.instance).to receive(:registered?).with(:kilocode).and_return(true)
      allow(AgentHarness::Providers::Registry.instance).to receive(:get).with(:kilocode).and_return(provider_class)
      allow(AgentHarness::Providers::Registry.instance).to receive(:canonical_name).with(:kilocode).and_return(:kilocode)
      allow(AgentHarness::Providers::Registry.instance).to receive(:smoke_test_contract).with(:kilocode).and_return({ timeout: contract_timeout })
      provider_class.contract_timeout = contract_timeout
      provider_class.provider_instance = provider_instance

      executor = instance_double(AgentHarness::DockerCommandExecutor)
      runtime = AgentHarness::ProviderRuntime.new(env: { "FOO" => "bar" })

      AgentHarness::ProviderHealthCheck.check(
        :kilocode,
        timeout: caller_timeout,
        executor: executor,
        provider_runtime: runtime
      )
      runtime
    end

    it "uses the caller timeout when it exceeds the smoke-test contract timeout" do
      provider_instance = provider_class.new(
        executor: instance_double(AgentHarness::CommandExecutor, which: "/usr/bin/kilo")
      )

      runtime = run_health_check(provider_instance: provider_instance, contract_timeout: 30, caller_timeout: 60)

      expect(provider_instance.received_smoke_test_timeout).to eq(60)
      expect(provider_instance.received_provider_runtime).to eq(runtime)
    end

    it "passes nil timeout when the contract timeout exceeds the caller timeout (adapter uses contract default)" do
      provider_instance = provider_class.new(
        executor: instance_double(AgentHarness::CommandExecutor, which: "/usr/bin/kilo")
      )

      runtime = run_health_check(provider_instance: provider_instance, contract_timeout: 90, caller_timeout: 60)

      # agent-harness ≥0.17.1 passes nil so the adapter falls through to
      # contract[:timeout]; the outer Timeout.timeout already uses
      # max(caller, contract) to prevent premature kills.
      expect(provider_instance.received_smoke_test_timeout).to be_nil
      expect(provider_instance.received_provider_runtime).to eq(runtime)
    end

    it "forwards unrelated smoke-test keywords while replacing a nil timeout" do
      provider_instance = Class.new do
        attr_reader :received_kwargs

        def smoke_test_contract
          { timeout: 30 }
        end

        def smoke_test(*args, **kwargs)
          @received_kwargs = kwargs
          { ok: true }
        end
      end.new

      provider_instance.instance_variable_set(:@paid_smoke_test_timeout, 60)
      provider_instance.singleton_class.prepend(AgentHarnessSmokeTestTimeoutProviderPatch)

      provider_instance.smoke_test(timeout: nil, provider_runtime: :runtime, sentinel: :value)

      expect(provider_instance.received_kwargs).to eq(
        timeout: 60,
        provider_runtime: :runtime,
        sentinel: :value
      )
    end

    it "forwards unrelated health-check keywords while storing the caller timeout" do
      health_check_class = Class.new do
        class << self
          attr_reader :received_args, :received_kwargs

          def perform_check(*args, **kwargs)
            @received_args = args
            @received_kwargs = kwargs
          end
        end
      end
      health_check_class.singleton_class.prepend(AgentHarnessSmokeTestTimeoutPatch)

      health_check_class.send(:perform_check, :kilocode, :start, timeout: 60, sentinel: :value)

      expect(health_check_class.received_args).to eq([ :kilocode, :start ])
      expect(health_check_class.received_kwargs).to eq(timeout: 60, sentinel: :value)
      expect(Thread.current[:paid_agent_harness_smoke_test_timeout]).to be_nil
    end
  end

  describe "#rate_limit_reset_at" do
    let(:account) { create(:account, slug: "test-agent-rate-limit-reset-account") }
    let(:user) { create(:user, account: account, email: "test-agent-rate-limit-reset@example.com") }

    before do
      allow(RunnerSupport).to receive(:harness_runner_key_for).with("claude").and_return("claude")
    end

    it "falls back when agent-harness parses a stale reset time" do
      harness_provider = double(parse_rate_limit_reset: 1.hour.ago)
      allow(AgentHarness).to receive(:provider).with(:claude).and_return(harness_provider)

      freeze_time do
        service = described_class.new(runner: provider)
        reset_at = service.send(:rate_limit_reset_at, "Rate limit exceeded. Reset at: 1")

        expect(reset_at).to eq(1.hour.from_now)
      end
    end
  end

  describe "#build_test_run" do
    let(:runner_record) { user.runners.find_or_create_by!(runner_key: "claude") }

    it "increments agent_runs_count for the lifetime of the callback-bypassed row" do
      service = described_class.new(runner: provider)

      test_run = service.send(:build_test_run)
      expect(project.reload.agent_runs_count).to eq(1)
    ensure
      test_run&.destroy!
      expect(project.reload.agent_runs_count).to eq(0)
    end
  end
end
