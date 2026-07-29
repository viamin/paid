# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAgentActivity, :no_db do
  describe "#base_prompt_for" do
    let(:activity) { described_class.new }

    it "uses the public base_prompt interface when no custom prompt is set" do
      agent_run = Struct.new(:custom_prompt, :base_prompt, keyword_init: true).new(
        custom_prompt: nil,
        base_prompt: "Base prompt"
      )

      expect(activity.send(:base_prompt_for, agent_run)).to eq("Base prompt")
    end

    it "prefers the custom prompt when present" do
      agent_run = Struct.new(:custom_prompt, :base_prompt, keyword_init: true).new(
        custom_prompt: "Custom prompt",
        base_prompt: "Base prompt"
      )

      expect(activity.send(:base_prompt_for, agent_run)).to eq("Custom prompt")
    end
  end

  describe "#effective_prompt_for" do
    let(:activity) { described_class.new }
    let(:agent_run) { Struct.new(:id, keyword_init: true).new(id: 42) }

    it "passes the provider key through to marketplace prompt injection" do
      allow(MarketplaceEntries::InjectIntoPrompt).to receive(:call).and_return("Rendered prompt")

      prompt = activity.send(
        :effective_prompt_for,
        agent_run: agent_run,
        base_prompt: "Base prompt",
        runner_key: "codex"
      )

      expect(prompt).to eq("Rendered prompt")
      expect(MarketplaceEntries::InjectIntoPrompt).to have_received(:call).with(
        agent_run: agent_run,
        prompt: "Base prompt",
        provider_key: "codex"
      )
    end
  end

  describe "#synchronize_marketplace_mcp_for_runner!" do
    let(:activity) { described_class.new }
    let(:attachments_relation) do
      Class.new do
        def exists?; end
      end
    end
    let(:agent_run) do
      Struct.new(
        :id,
        :agent_run_marketplace_entries,
        :mcp_server_snapshot,
        :mcp_provisioned_servers,
        keyword_init: true
      ).new(
        id: 1,
        agent_run_marketplace_entries: attachments,
        mcp_server_snapshot: initial_snapshot,
        mcp_provisioned_servers: initial_provisioned_servers
      )
    end
    let(:attachments) { instance_double(attachments_relation, exists?: true) }
    let(:initial_snapshot) { [ { "name" => "old-marketplace-server", "marketplace_attachment" => true } ] }
    let(:initial_provisioned_servers) { { "stdio_servers" => [ { "name" => "old-marketplace-server" } ], "url_servers" => [] } }
    let(:provisioner_class) do
      Class.new do
        def provision(*); end
      end
    end
    let(:provisioner) { instance_double(provisioner_class) }
    let(:agent_run_class) do
      Class.new do
        def self.transaction
          yield
        end
      end
    end

    before do
      stub_const("AgentRun", agent_run_class)
      allow(MarketplaceEntries::RerenderForRun).to receive(:call) do |agent_run:, provider_key:|
        agent_run.mcp_server_snapshot = [ { "name" => "#{provider_key}-server", "marketplace_attachment" => true } ]
      end
      allow(Containers::McpProvisioner).to receive(:new).and_return(provisioner)
      allow(provisioner).to receive(:provision)
      allow(Containers::Provision).to receive(:network_for).with(agent_run: agent_run).and_return("paid-network")
      allow(activity).to receive(:runner_entry_for).and_return(nil)
    end

    it "re-renders and re-provisions marketplace MCP servers for the provider attempt" do
      activity.send(
        :synchronize_marketplace_mcp_for_runner!,
        agent_run: agent_run,
        runner_candidate: "codex",
        runner: "codex",
        user: nil
      )

      expect(MarketplaceEntries::RerenderForRun).to have_received(:call).with(agent_run: agent_run, provider_key: "codex")
      expect(provisioner).to have_received(:provision).with(agent_run, network: "paid-network")
    end

    it "skips reprovision when the snapshot is unchanged and provisioned MCP state already exists" do
      allow(MarketplaceEntries::RerenderForRun).to receive(:call)

      activity.send(
        :synchronize_marketplace_mcp_for_runner!,
        agent_run: agent_run,
        runner_candidate: "codex",
        runner: "codex",
        user: nil
      )

      expect(provisioner).not_to have_received(:provision)
    end

    it "caches marketplace attachment existence across provider retries" do
      2.times do
        activity.send(
          :synchronize_marketplace_mcp_for_runner!,
          agent_run: agent_run,
          runner_candidate: "codex",
          runner: "codex",
          user: nil
        )
      end

      expect(attachments).to have_received(:exists?).once
    end
  end

  describe "#command_env_for" do
    let(:activity) { described_class.new }
    let(:command_context_class) do
      Struct.new(:runner_candidate, :runner, :user, keyword_init: true)
    end
    let(:provider_entry) do
      double(
        agent_harness_runtime?: false,
        provider_key: "codex",
        requires_direct_outbound?: requires_direct_outbound,
        direct_outbound_exec_env: direct_outbound_exec_env,
        api_key?: api_key
      )
    end
    let(:requires_direct_outbound) { true }
    let(:direct_outbound_exec_env) { { "OPENROUTER_API_KEY" => "secret" } }
    let(:api_key) { true }
    let(:command_context) do
      command_context_class.new(runner_candidate: "fallback", runner: "codex", user: nil)
    end
    let(:marketplace_env) { { "MARKETPLACE_FLAG" => "enabled" } }

    before do
      allow(activity).to receive_messages(
        marketplace_runtime_env: marketplace_env,
        runner_entry_for: provider_entry
      )
      allow(activity).to receive(:api_key_command_env).with(provider_entry).and_return(
        "PAID_PROVIDER_ID" => "42"
      )
    end

    it "duplicates the memoized marketplace env before adding provider-specific variables" do
      env = activity.send(:command_env_for, command_context, "ping")

      expect(env).to eq(
        "MARKETPLACE_FLAG" => "enabled",
        "OPENROUTER_API_KEY" => "secret",
        "PAID_PROVIDER_ID" => "42"
      )
      expect(marketplace_env).to eq("MARKETPLACE_FLAG" => "enabled")
    end

    it "does not leak env from one fallback provider candidate into the next" do
      first_provider = provider_entry
      second_provider = double(
        agent_harness_runtime?: false,
        provider_key: "codex",
        requires_direct_outbound?: false,
        direct_outbound_exec_env: {},
        api_key?: false
      )
      allow(activity).to receive(:runner_entry_for).and_return(
        first_provider,
        second_provider
      )

      first_env = activity.send(:command_env_for, command_context, "ping")
      second_env = activity.send(:command_env_for, command_context, "ping")

      expect(first_env).to include("OPENROUTER_API_KEY" => "secret", "PAID_PROVIDER_ID" => "42")
      expect(second_env).to eq("MARKETPLACE_FLAG" => "enabled")
      expect(marketplace_env).to eq("MARKETPLACE_FLAG" => "enabled")
    end
  end

  describe "#direct_outbound_runner?" do
    let(:activity) { described_class.new }

    it "treats bare openrouter_pareto candidates as direct outbound" do
      allow(activity).to receive(:runner_entry_for).with("openrouter_pareto", nil).and_return(nil)

      expect(activity.send(:direct_outbound_runner?, "openrouter_pareto", nil)).to be(true)
    end
  end

  describe "#preflight_timeout_seconds_for" do
    let(:activity) { described_class.new }

    it "prefers a configured runner-specific timeout override on the runner entry" do
      runner_entry = instance_double(
        Runner,
        runner_preflight_timeout_seconds: 45,
        requires_direct_outbound?: true
      )
      allow(activity).to receive(:provider_entry_for).and_return(runner_entry)

      timeout = activity.send(:preflight_timeout_seconds_for, "runner:19", nil)

      expect(timeout).to eq(45)
    end

    it "falls back to the direct-outbound default when no override is configured" do
      runner_entry = instance_double(
        Runner,
        runner_preflight_timeout_seconds: nil,
        requires_direct_outbound?: true
      )
      allow(activity).to receive(:provider_entry_for).and_return(runner_entry)

      timeout = activity.send(:preflight_timeout_seconds_for, "runner:19", nil)

      expect(timeout).to eq(described_class::DIRECT_OUTBOUND_PREFLIGHT_TIMEOUT_SECONDS)
    end
  end

  describe "#redact_tool_output_for_classification" do
    let(:activity) { described_class.new }

    # A codex command_execution event whose aggregated_output is the verbatim
    # contents of a source file that *defines* rate-limit trigger phrases.
    let(:file_echo_event) do
      JSON.generate(
        "type" => "item.completed",
        "item" => {
          "id" => "item_1",
          "type" => "command_execution",
          "command" => "/bin/bash -lc \"sed -n '1,5p' run_agent_activity.rb\"",
          "aggregated_output" => "/quota exceeded/i,\n/free tier limit reached/i,\n/too many requests/i",
          "exit_code" => 0
        }
      )
    end

    it "blanks verbatim command output and the command string for codex" do
      redacted = activity.send(:redact_tool_output_for_classification, "codex", file_echo_event)

      parsed = JSON.parse(redacted)
      expect(parsed.dig("item", "aggregated_output")).to eq("")
      expect(parsed.dig("item", "command")).to eq("")
      # Event structure (type, id, exit_code, status) is preserved.
      expect(parsed["type"]).to eq("item.completed")
      expect(parsed.dig("item", "type")).to eq("command_execution")
      expect(parsed.dig("item", "exit_code")).to eq(0)
    end

    it "blanks the agent's own narration (agent_message text)" do
      agent_message = JSON.generate(
        "type" => "item.completed",
        "item" => { "type" => "agent_message", "text" => "I will fix the rate limit detection." }
      )

      redacted = activity.send(:redact_tool_output_for_classification, "codex", agent_message)

      expect(JSON.parse(redacted).dig("item", "text")).to eq("")
    end

    it "preserves explicit error payloads (the real provider signal)" do
      error_event = JSON.generate(
        "type" => "turn.failed",
        "error" => { "message" => "429 Too Many Requests: rate limit exceeded" }
      )

      redacted = activity.send(:redact_tool_output_for_classification, "codex", error_event)

      expect(redacted).to include("429 Too Many Requests: rate limit exceeded")
    end

    it "leaves non-JSON (plain stderr) lines untouched" do
      stderr = "error: your access token could not be refreshed because 401 unauthorized"

      expect(activity.send(:redact_tool_output_for_classification, "codex", stderr)).to eq(stderr)
    end

    it "returns output unchanged for non-codex runners" do
      expect(activity.send(:redact_tool_output_for_classification, "claude", file_echo_event))
        .to eq(file_echo_event)
    end

    it "returns blank input unchanged" do
      expect(activity.send(:redact_tool_output_for_classification, "codex", "")).to eq("")
    end
  end

  describe "rate-limit classification after tool-output redaction" do
    let(:activity) { described_class.new }

    # Reproduces the false positive: codex reads source files that define the
    # rate-limit patterns, echoing them into command_execution.aggregated_output.
    let(:file_echo_event) do
      JSON.generate(
        "type" => "item.completed",
        "item" => {
          "type" => "command_execution",
          "command" => "/bin/bash -lc \"cat run_agent_activity.rb\"",
          "aggregated_output" => "/quota exceeded/i, /free tier limit reached/i, /too many requests/i, /rate.?limit/i"
        }
      )
    end

    # The agent narrating its work on rate-limit code — caught by the broad
    # exit-failure pattern /rate.?limit/i before redaction.
    let(:prose_event) do
      JSON.generate(
        "type" => "item.completed",
        "item" => { "type" => "agent_message", "text" => "Done — I refactored the rate limit detection and quota exceeded handling." }
      )
    end

    it "does not classify echoed source as a timeout rate limit" do
      redacted = activity.send(:redact_tool_output_for_classification, "codex", file_echo_event)

      expect(activity.send(:timeout_rate_limit_error?, redacted, runner_key: "codex")).to be(false)
    end

    it "does not classify echoed source as an exit-failure rate limit" do
      redacted = activity.send(:redact_tool_output_for_classification, "codex", file_echo_event)

      expect(activity.send(:rate_limit_error?, redacted, runner_key: "codex")).to be(false)
    end

    it "does not classify the agent's own narration as an exit-failure rate limit" do
      redacted = activity.send(:redact_tool_output_for_classification, "codex", prose_event)

      expect(activity.send(:rate_limit_error?, redacted, runner_key: "codex")).to be(false)
    end

    it "still classifies a genuine codex rate-limit error event after redaction" do
      real_error = JSON.generate(
        "type" => "turn.failed",
        "error" => { "message" => "429 status: too many requests" }
      )
      redacted = activity.send(:redact_tool_output_for_classification, "codex", real_error)

      expect(activity.send(:rate_limit_error?, redacted, runner_key: "codex")).to be(true)
    end
  end

  describe "#container_not_running_error?" do
    let(:activity) { described_class.new }

    it "matches Docker container-death messages" do
      expect(activity.send(:container_not_running_error?, "container abc123 is not running")).to be(true)
      expect(activity.send(:container_not_running_error?, "Docker exec error: Failed to restore prepared runtime state: container abc is not running")).to be(true)
      expect(activity.send(:container_not_running_error?, "No such container: abc")).to be(true)
    end

    it "does not match unrelated runner errors" do
      expect(activity.send(:container_not_running_error?, "Agent exited with code 1: invalid model")).to be(false)
      expect(activity.send(:container_not_running_error?, nil)).to be(false)
    end
  end

  describe "#deterministic_runner_config_error?" do
    let(:activity) { described_class.new }

    it "matches ProviderModelNotFoundError messages" do
      expect(activity.send(:deterministic_runner_config_error?,
        "Runner model not found error from claude: Error: Model not found: bad-model\nProviderModelNotFoundError")).to be(true)
    end

    it "matches 'Error: Model not found:' messages" do
      expect(activity.send(:deterministic_runner_config_error?,
        "Agent exited with code 1: Error: Model not found: MiniMax-M3")).to be(true)
    end

    it "matches CLI version outdated messages" do
      expect(activity.send(:deterministic_runner_config_error?,
        "Agent exited with code 1: The 'gpt-5.5' model requires a newer version of Codex CLI")).to be(true)
    end

    it "does not match transient infra errors" do
      expect(activity.send(:deterministic_runner_config_error?, "Agent exited with code 1: connection refused")).to be(false)
      expect(activity.send(:deterministic_runner_config_error?, "Agent exited with code 1: timeout waiting for response")).to be(false)
    end

    it "returns false for blank messages" do
      expect(activity.send(:deterministic_runner_config_error?, nil)).to be(false)
      expect(activity.send(:deterministic_runner_config_error?, "")).to be(false)
    end
  end
end
