# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserSetting do
  let(:owner) { create(:user) }
  let(:setting) { owner.settings }
  let(:runner) { create(:runner, user: owner, runner_key: "gemini") }

  # @spec LLM-ROUTING-001
  it "accepts a specific owned chat runner and selects that record" do
    setting.update!(kb_chat_runner: runner.routing_key)

    expect(Llm::RunnerSelection.candidates(user: owner).first).to eq(runner)
    expect(setting.knowledge_runner_options(operation: :chat).map(&:last)).to include(runner.routing_key)
  end

  # @spec LLM-ROUTING-002
  it "rejects another user's runner identifier" do
    other = create(:runner, runner_key: "gemini")
    setting.kb_chat_runner = other.routing_key

    expect(setting).not_to be_valid
    expect(setting.errors[:kb_chat_runner]).to be_present
  end

  # @spec LLM-ROUTING-002
  it "rejects a runner with chat usage disabled" do
    runner.update_column(:enabled_for_chat, false)
    setting.kb_chat_runner = runner.routing_key

    expect(setting).not_to be_valid
  end

  # @spec LLM-ROUTING-002
  it "does not substitute another runner when an explicitly selected runner is disabled and fallback is off" do
    setting.update!(kb_chat_runner: runner.routing_key, fallback_enabled: false)
    runner.update_column(:enabled_for_chat, false)

    expect(Llm::RunnerSelection.candidates(user: owner)).to be_empty
    expect(setting.reload).to be_valid
  end

  # @spec LLM-ROUTING-002
  it "allows editing other preferences after a saved fallback runner is disabled" do
    setting.update!(kb_chat_fallback_runners: [ runner.routing_key ])
    runner.update_column(:enabled_for_chat, false)

    expect(setting.reload.update(fallback_enabled: false)).to be(true)
    expect(Llm::RunnerSelection.candidates(user: owner)).not_to include(runner)
  end
end
