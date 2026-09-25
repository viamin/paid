# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_chat_system_prompt_problem_framing.rb").sole

RSpec.describe SyncChatSystemPromptProblemFraming, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: ChatSessions::BuildSystemPrompt::CHAT_SYSTEM_PROMPT_SLUG).destroy_all
    end
  end

  # @spec FEATURE-CREATION-007
  it "updates an existing global chat prompt with problem-framing guidance" do
    prompt = create(:prompt, :global, slug: ChatSessions::BuildSystemPrompt::CHAT_SYSTEM_PROMPT_SLUG)
    previous_version = prompt.create_version!(template: "old chat prompt", variables: [], created_by: "seed")

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)

    expect(prompt.current_version).not_to eq(previous_version)
    expect(prompt.current_version.template).to include("selected_framing_confirmed")
    expect(prompt.current_version.template).to include("only after the user confirms the framing")
    expect(prompt.current_version.created_by).to eq("migration")
  end

  # @spec FEATURE-CREATION-007
  it "is idempotent when the current chat prompt has the expected guidance" do
    prompt = create(:prompt, :global, slug: ChatSessions::BuildSystemPrompt::CHAT_SYSTEM_PROMPT_SLUG)
    migration.up

    expect { migration.up }.not_to change { prompt.reload.prompt_versions.count }
  end
end
