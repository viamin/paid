# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_enhance_issue_structured_questions_prompt.rb").sole

RSpec.describe SyncEnhanceIssueStructuredQuestionsPrompt, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: "goal.enhance_issue").destroy_all
    end
  end

  it "updates a prompt that has no current version" do # @spec ISSUE-ENHANCEMENT-020
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)
    expect(prompt.current_version.template).to eq(described_class::TEMPLATE)
    expect(prompt.current_version.variables).to eq(described_class::VARIABLES)
    expect(prompt.current_version.template).to include('"choice_type": "single"')
  end

  it "does not depend on the live fallback prompt" do # @spec ISSUE-ENHANCEMENT-020
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    stub_const("Activities::RunAgentActivity::FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT", "future template")

    migration.up

    expect(prompt.reload.current_version.template).to eq(described_class::TEMPLATE)
    expect(prompt.current_version.template).not_to eq("future template")
  end
end
