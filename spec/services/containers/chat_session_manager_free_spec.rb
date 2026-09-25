# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::ChatSessionManager do
  let(:user) { create(:user) }
  let!(:model) do
    create(:llm_model, :free, model_id: "vendor/chat:free", catalog_source: "openrouter_sync",
      supports_tools: true, metadata: { "architecture" => { "output_modalities" => [ "text" ] } })
  end

  let(:project) { create(:project, account: user.account) }
  let(:runner) do
    create(:runner, user: user, runner_key: "opencode", auth_type: "api_key",
      provider_api_key: create(:provider_api_key, user: user, api_service_type: "openrouter"),
      enabled_for_agent_runs: false, enabled_for_fallback: false,
      config: { "opencode" => { "model_policy" => "free" } })
  end
  let(:session) do
    create(:chat_session, :workspace, :with_project, account: user.account,
      created_by: user, runner: runner, project: project, model: "openrouter/free", container_id: "free-chat")
  end
  let(:configurations) { [] }
  let(:manager) { described_class.new(session) }

  before do
    container = instance_double(Docker::Container, refresh!: true, info: { "State" => { "Running" => true } })
    allow(Docker::Container).to receive(:get).with("free-chat").and_return(container)
    allow(container).to receive(:exec) do |_command, **options|
      encoded = Array(options[:Env]).find { |entry| entry.start_with?("PAID_PREPARATION_B64=") }
      configurations << JSON.parse(Base64.decode64(encoded.split("=", 2).last)) if encoded
      [ [], [], 0 ]
    end
  end

  # @spec MODEL-POLICY-013
  it "materializes an eligible concrete model and rejects an empty pool before executing a prompt" do
    expect(manager.execute_agent_command(prompt: "Reply OK")).to be_success
    expect(configurations).to include(hash_including("model" => "openrouter/vendor/chat:free"))

    model.update!(active: false)
    expect { manager.execute_agent_command(prompt: "Reply OK") }.to raise_error(ChatSessions::LlmClientConfigurationError, /No eligible/)
  end

  # @spec CHAT-API-019
  it "enforces the most sensitive reference project's routing in the real execution plan" do
    sensitive = create(:project, account: user.account, data_classification: "restricted")
    session.chat_session_projects.create!(project: sensitive, context_type: "reference")

    expect(manager.execute_agent_command(prompt: "Reply OK")).to be_success
    expect(configurations.last.dig("provider", "openrouter")).to include("data_collection" => "deny", "zdr" => true)
  end
end
