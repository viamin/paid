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
end
