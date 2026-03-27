# frozen_string_literal: true

require "rails_helper"

RSpec.describe Providers::TestAgent do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account, created_by: user) }
  let!(:project) { create(:project, account: account, github_token: github_token, created_by: user) }
  let(:provider_record) { user.providers.find_or_create_by!(provider_key: "claude") }
  let(:provider) { provider_record }
  let(:test_run) do
    instance_double(
      AgentRun,
      with_container: container_result,
      persisted?: true,
      destroy!: true,
      execute_in_container: execution_result
    )
  end
  let(:execution_result) do
    Containers::Provision::Result.success(stdout: "PING OK", stderr: "", exit_code: 0)
  end
  let(:container_result) { execution_result }

  describe ".call" do
    context "when agent-harness health check succeeds" do
      let(:health_result) { { name: :claude, status: "ok", message: "All checks passed", latency_ms: 12 } }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "claude")
        allow(AgentRun).to receive(:create!)
        allow(AgentHarness).to receive(:check_provider).and_return(health_result)
      end

      it "returns a successful result" do
        result = described_class.call(provider: provider)

        expect(result).to be_success
        expect(result.message).to eq("Agent is healthy")
        expect(result.error_type).to be_nil
      end

      it "uses agent-harness for the health check" do
        described_class.call(provider: provider)

        expect(AgentHarness).to have_received(:check_provider).with(:claude, timeout: 30)
        expect(AgentRun).not_to have_received(:create!)
      end
    end

    context "when agent-harness health check reports an auth error" do
      let(:health_result) { { name: :claude, status: "error", message: "Session expired", latency_ms: 12 } }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "claude")
        allow(AgentHarness).to receive(:check_provider).and_return(health_result)
      end

      it "maps the health check failure to an authentication error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Session expired")
      end
    end

    context "when codex needs the repo trust check disabled for provider tests" do
      let(:provider_record) { create(:provider, user: user, provider_key: "codex", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "codex")
        allow(AgentRun).to receive(:create!).and_return(test_run)
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "adds the skip git repo check flag" do
        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          a_string_including('if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]')
            .and(include("-u OPENAI_API_KEY"))
            .and(include("codex exec --full-auto --skip-git-repo-check --output-last-message")),
          timeout: 30,
          stream: false
        )
      end
    end

    context "when gemini is tested with optional subscription auth" do
      let(:provider_record) { create(:provider, user: user, provider_key: "gemini", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "gemini")
        allow(AgentRun).to receive(:create!).and_return(test_run)
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "unsets Gemini proxy env vars when subscription auth is available" do
        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          a_string_including('if [ "$PAID_GEMINI_SUBSCRIPTION_AUTH" = "1" ]')
            .and(include("-u GEMINI_API_KEY"))
            .and(include("-u GOOGLE_GEMINI_BASE_URL"))
            .and(include("gemini -y -p")),
          timeout: 30,
          stream: false
        )
      end
    end

    context "when kilocode is tested in automation mode" do
      let(:provider_record) { create(:provider, user: user, provider_key: "kilocode", enabled_for_agent_runs: false, enabled_for_fallback: false) }

      before do
        allow(ProviderSupport).to receive_messages(supported_provider_key?: true,
          container_executable_provider_key?: true, harness_provider_key_for: "kilocode")
        allow(AgentRun).to receive(:create!).and_return(test_run)
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "adds the auto approval flag" do
        described_class.call(provider: provider)

        expect(test_run).to have_received(:execute_in_container).with(
          a_string_including('env -u OPENAI_API_KEY').and(include('timeout 20s kilo run --auto --print-logs')),
          timeout: 30,
          stream: false
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
        allow(test_run).to receive(:with_container).and_yield(test_run)
      end

      it "returns a concise authentication error" do
        result = described_class.call(provider: provider)

        expect(result).not_to be_success
        expect(result.error_type).to eq(:authentication)
        expect(result.message).to eq("Codex did not forward the Paid container credentials to the OpenAI proxy.")
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
        allow(test_run).to receive(:with_container)
          .and_raise(Containers::Provision::ProvisionError, "Invalid API key")
      end

      it "returns an authentication error" do
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
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
        allow(AgentRun).to receive(:create!).and_return(test_run)
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
        allow(AgentRun).to receive(:create!)
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
