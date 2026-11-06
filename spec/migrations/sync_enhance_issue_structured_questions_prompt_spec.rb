# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_enhance_issue_structured_questions_prompt.rb").sole

RSpec.describe SyncEnhanceIssueStructuredQuestionsPrompt do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: "goal.enhance_issue").destroy_all
    end
  end

  it "updates a prompt that has no current version" do # @spec ISSUE-ENHANCEMENT-020
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)
    expect(prompt.current_version.variables).to eq([])
  end
end
