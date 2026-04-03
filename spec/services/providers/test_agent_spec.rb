# frozen_string_literal: true

require "rails_helper"

RSpec.describe Providers::TestAgent do
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

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account, created_by: user) }
  let!(:project) { create(:project, account: account, github_token: github_token, created_by: user) }
  let(:provider_record) { user.providers.find_or_create_by!(provider_key: "claude") }
  let(:provider) { provider_record }
  let(:execution_result) do
    Containers::Provision::Result.success(stdout: "PING OK", stderr: "", exit_code: 0)
  end
  let(:test_run) do
    instance_double(
      AgentRun,
      id: 1,
      with_container: execution_result,
      persisted?: true,
      destroy!: true,
      execute_in_container: execution_result
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

  describe ".call" do
    context "when claude is tested through the container runtime path" do
      let(:provider_record) { user.providers.find_or_create_by!(provider_key: "claude").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "claude")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns a successful result" do
        result = described_class.call(provider: provider)

        expect(result).to be_success
        expect(result.message).to eq("Agent is healthy")
        expect(result.error_type).to be_nil
      end

      it "executes the claude cli inside the container" do
        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          array_including("claude", "--print", "--output-format=text", "--dangerously-skip-permissions", "-p", "Respond with exactly: PING OK"),
          timeout: 60,
          stream: false,
          env: {}
        )
      end
    end

    context "when claude returns an auth error from the container runtime path" do
      let(:provider_record) { user.providers.find_or_create_by!(provider_key: "claude").tap { |p| p.update!(enabled_for_agent_runs: true, enabled_for_fallback: false) } }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: "No authentication token found",
          stdout: "",
          stderr: "No authentication token found",
          exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "claude")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "maps the health check failure to an authentication error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("No authentication token found")
      end
    end

    context "when codex has a Paid-managed OpenAI API key configured" do
      let(:provider_record) { create(:provider, user: user, provider_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:health_result) { { name: :codex, status: "ok", message: "All checks passed", latency_ms: 12 } }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "codex")
        stub_proxy_api_key(:openai, "sk-test-key")
        allow(AgentHarness).to receive(:check_provider).and_return(health_result)
      end

      it "uses agent-harness for the health check" do
        result = described_class.call(provider: provider)

        expect(result).to be_success
        expect(AgentHarness).to have_received(:check_provider).with(:codex, timeout: 60)
      end
    end

    context "when gemini has a Paid-managed Google API key configured" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:health_result) { { name: :gemini, status: "ok", message: "All checks passed", latency_ms: 12 } }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_proxy_api_key(:google, "AIza-test-key")
        allow(AgentHarness).to receive(:check_provider).and_return(health_result)
      end

      it "uses agent-harness for the health check" do
        result = described_class.call(provider: provider)

        expect(result).to be_success
        expect(AgentHarness).to have_received(:check_provider).with(:gemini, timeout: 60)
      end
    end

    context "when codex needs the repo trust check disabled for provider tests" do
      let(:provider_record) { create(:provider, user: user, provider_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "codex")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "adds the skip git repo check flag" do
        service = described_class.new(provider: provider)
        base_command = Providers::TestAgent::CONTAINER_COMMANDS.fetch("codex")
        codex_command = service.send(
          :command_with_flags_before_separator,
          base_command,
          "--skip-git-repo-check",
          "--output-last-message",
          "$tmp_output"
        ).join(" ")

        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          a_string_including('if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]')
            .and(include("-u OPENAI_API_KEY"))
            .and(include(codex_command)),
          timeout: 60,
          stream: false,
          env: {}
        )
      end
    end

    context "when a stale codex provider state exists and the test succeeds" do
      let(:provider_record) { create(:provider, user: user, provider_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let!(:provider_state) do
        create(
          :provider_state,
          :rate_limited,
          :circuit_half_open,
          user: user,
          provider_name: "codex"
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "codex")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "clears the stale provider state" do
        result = described_class.call(provider: provider)

        expect(result).to be_success

        provider_state.reload
        expect(provider_state.failure_count).to eq(0)
        expect(provider_state.circuit_state).to eq("closed")
        expect(provider_state.circuit_opened_at).to be_nil
        expect(provider_state.rate_limited_until).to be_nil
      end
    end

    context "when gemini is tested with optional subscription auth" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "unsets Gemini proxy env vars when subscription auth is available" do
        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          a_string_including('if [ "$PAID_GEMINI_SUBSCRIPTION_AUTH" = "1" ]')
            .and(include("-u GEMINI_API_KEY"))
            .and(include("-u GOOGLE_GEMINI_BASE_URL"))
            .and(include("gemini -y -p"))
            .and(include('grep -q "Error when talking to Gemini API"'))
            .and(include('ruby -rjson -e')),
          timeout: 60,
          stream: false,
          env: {}
        )
      end
    end

    context "when kilocode is tested in automation mode" do
      let(:provider_record) { create(:provider, user: user, provider_key: "kilocode", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "kilocode")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "adds the auto approval flag" do
        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          a_string_including('env -u OPENAI_API_KEY').and(include('timeout 20s kilo run --auto --print-logs')),
          timeout: 60,
          stream: false,
          env: {}
        )
      end
    end

    context "when agent returns a failure response" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: "Process exited abnormally",
          stdout: "",
          stderr: "Process exited abnormally",
          exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns an unexpected error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to include("Process exited abnormally")
      end
    end

    context "when gemini exits with an auth setup error in stderr" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: "Please set an Auth method in your /home/agent/.gemini/settings.json or specify one of the following environment variables before running: GEMINI_API_KEY, GOOGLE_GENAI_USE_VERTEXAI, GOOGLE_GENAI_USE_GCA",
          stdout: "",
          stderr: "Please set an Auth method in your /home/agent/.gemini/settings.json or specify one of the following environment variables before running: GEMINI_API_KEY, GOOGLE_GENAI_USE_VERTEXAI, GOOGLE_GENAI_USE_GCA",
          exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns an authentication error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to include("Please set an Auth method")
      end
    end

    context "when gemini returns a validation-required stack trace" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: <<~ERROR,
            Keychain initialization encountered an error: Cannot autolaunch D-Bus without X11 $DISPLAY
            Using FileKeychain fallback for secure storage.
            Loaded cached credentials.
            Validation handler failed: ValidationRequiredError: Verify your account to continue.
                at classifyValidationRequiredError (file:///tmp/googleQuotaErrors.js:141:12)
            Error when talking to Gemini API
            Full report available at: /tmp/gemini-client-error.json
            ValidationRequiredError: Verify your account to continue.
                at Turn.run (file:///tmp/turn.js:71:30)
            An unexpected critical error occurred:[object Object]
          ERROR
          stdout: "",
          stderr: <<~ERROR,
            Keychain initialization encountered an error: Cannot autolaunch D-Bus without X11 $DISPLAY
            Using FileKeychain fallback for secure storage.
            Loaded cached credentials.
            Validation handler failed: ValidationRequiredError: Verify your account to continue.
                at classifyValidationRequiredError (file:///tmp/googleQuotaErrors.js:141:12)
            Error when talking to Gemini API
            Full report available at: /tmp/gemini-client-error.json
            ValidationRequiredError: Verify your account to continue.
                at Turn.run (file:///tmp/turn.js:71:30)
            An unexpected critical error occurred:[object Object]
          ERROR
          exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns a concise authentication error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Verify your account to continue.")
      end
    end

    context "when gemini hits the proxy without a configured upstream key" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: "[API Error: {\"error\":\"API key not configured for google\"}]",
          stdout: "",
          stderr: "[API Error: {\"error\":\"API key not configured for google\"}]",
          exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns a concise authentication error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Paid is not configured with a Google API key for containerized Gemini runs.")
      end
    end

    context "when codex cannot authenticate to the Paid proxy" do
      let(:provider_record) { create(:provider, user: user, provider_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: "Unauthorized: {\"error\":\"Missing agent run ID\"}, url: http://web:3000/api/proxy/openai/responses",
          stdout: "",
          stderr: "Unauthorized: {\"error\":\"Missing agent run ID\"}, url: http://web:3000/api/proxy/openai/responses",
          exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "codex")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns a concise authentication error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Codex did not forward the Paid container credentials to the OpenAI proxy.")
      end
    end

    context "when opencode emits ansi noise before an auth failure" do
      let(:provider_record) { create(:provider, user: user, provider_key: "opencode", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: "\e[0m▄\e[0m\n[API Error: {\"error\":\"API key not configured for openai\"}]",
          stdout: "",
          stderr: "\e[0m▄\e[0m\n[API Error: {\"error\":\"API key not configured for openai\"}]",
          exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "opencode")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns the translated auth error instead of ansi noise" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Paid is not configured with an OpenAI API key for containerized OpenAI-backed runs (Codex or OpenCode).")
      end
    end

    context "when copilot is missing from an outdated agent image" do
      let(:provider_record) { create(:provider, user: user, provider_key: "copilot", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: 'OCI runtime exec failed: exec failed: unable to start container process: exec: "github-copilot-cli": executable file not found in $PATH',
          stdout: "",
          stderr: 'OCI runtime exec failed: exec failed: unable to start container process: exec: "github-copilot-cli": executable file not found in $PATH',
          exit_code: 126
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "github_copilot")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns a concise installation error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:installation)
        expect(result.message).to eq("GitHub Copilot CLI is missing from the agent container. Rebuild the paid-agent image to install the fixed Copilot CLI package.")
      end
    end

    context "when opencode is tested" do
      let(:provider_record) { create(:provider, user: user, provider_key: "opencode", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "opencode")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "uses the current opencode run command" do
        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          array_including("opencode", "run", "Respond with exactly: PING OK"),
          timeout: 60,
          stream: false,
          env: {}
        )
      end
    end

    context "when direct-outbound opencode is tested" do
      let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }
      let(:provider_record) do
        create(
          :provider,
          user: user,
          provider_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          enabled_for_agent_runs: false,
          enabled_for_fallback: false,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "opencode")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "passes the OpenCode config through exec env instead of the command string" do
        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          array_including("sh", "-lc", a_string_including('printf \'%s\' "$PAID_OPENCODE_CONFIG_B64" | base64 -d').and(include('opencode run "$1"'))),
          timeout: 60,
          stream: false,
          env: hash_including("PAID_OPENCODE_CONFIG_B64")
        )
      end

      it "only clears the routing-key state for api-key entries" do
        routing_state = create(:provider_state, user: user, provider_name: provider.state_key, failure_count: 2)
        provider_key_state = create(:provider_state, user: user, provider_name: provider.provider_key, failure_count: 3)

        described_class.call(provider: provider)

        expect(routing_state.reload.failure_count).to eq(0)
        expect(provider_key_state.reload.failure_count).to eq(3)
      end
    end

    context "when the provider reports a rate limit message on stdout" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }
      let(:execution_result) do
        Containers::Provision::Result.failure(
          error: "Command exited with code 1",
          stdout: "You're out of extra usage · resets 8am (UTC)\n",
          stderr: "",
          exit_code: 1
        )
      end

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns a rate limited error with the provider message" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:rate_limited)
        expect(result.message).to eq("You're out of extra usage · resets 8am (UTC)")
      end
    end

    context "when container provisioning surfaces an authentication-style message" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container)
          .and_raise(Containers::Provision::ProvisionError, "Invalid API key")
      end

      it "returns a connection error because provision failures are infrastructure errors" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:connection)
        expect(result.message).to eq("Invalid API key")
      end
    end

    context "when the agent times out" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container)
          .and_raise(Containers::Provision::TimeoutError, "Timed out after 30s")
      end

      it "returns a timeout error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:timeout)
        expect(result.message).to eq("Timed out after 30s")
      end
    end

    context "when a generic container error occurs" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        stub_insert_all
        allow(test_run).to receive(:with_container)
          .and_raise(Containers::Provision::ProvisionError, "Connection refused")
      end

      it "returns a connection error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:connection)
        expect(result.message).to eq("Connection refused")
      end
    end

    context "when the provider is unsupported" do
      before do
        allow(ProviderSupport).to receive(:supported_provider_key?).and_return(false)
      end

      it "returns an unexpected error indicating the provider is unrecognized" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to include("not recognized by the agent harness")
      end
    end

    context "when the provider is supported but not container-executable" do
      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: false)
      end

      it "returns an installation error indicating the CLI is not installed" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:installation)
        expect(result.message).to include("CLI is not installed in the agent container")
      end
    end

    context "when the user has no project context for a containerized test" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        project.destroy!
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
      end

      it "returns a helpful error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to eq("Add a project before testing providers in the agent container")
      end
    end

    context "when an unexpected error occurs" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        allow(AgentRun).to receive(:insert_all!)
          .and_raise(RuntimeError, "Something went wrong")
      end

      it "returns an unexpected error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:unexpected)
        expect(result.message).to eq("Something went wrong")
      end
    end
  end
end
