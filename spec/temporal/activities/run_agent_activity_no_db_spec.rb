# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAgentActivity, :no_db do
  describe "#command_env_for" do
    let(:activity) { described_class.new }
    let(:command_context_class) do
      Struct.new(:provider_candidate, :provider, :user, keyword_init: true)
    end
    let(:provider_entry) do
      double(
        agent_harness_runtime?: false,
        requires_direct_outbound?: requires_direct_outbound,
        direct_outbound_exec_env: direct_outbound_exec_env,
        api_key?: api_key
      )
    end
    let(:requires_direct_outbound) { true }
    let(:direct_outbound_exec_env) { { "OPENROUTER_API_KEY" => "secret" } }
    let(:api_key) { true }
    let(:command_context) do
      command_context_class.new(provider_candidate: "fallback", provider: "codex", user: nil)
    end
    let(:marketplace_env) { { "MARKETPLACE_FLAG" => "enabled" } }

    before do
      allow(activity).to receive_messages(
        marketplace_runtime_env: marketplace_env,
        provider_entry_for: provider_entry
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
        requires_direct_outbound?: false,
        direct_outbound_exec_env: {},
        api_key?: false
      )
      allow(activity).to receive(:provider_entry_for).and_return(first_provider, second_provider)

      first_env = activity.send(:command_env_for, command_context, "ping")
      second_env = activity.send(:command_env_for, command_context, "ping")

      expect(first_env).to include("OPENROUTER_API_KEY" => "secret", "PAID_PROVIDER_ID" => "42")
      expect(second_env).to eq("MARKETPLACE_FLAG" => "enabled")
      expect(marketplace_env).to eq("MARKETPLACE_FLAG" => "enabled")
    end
  end
end
