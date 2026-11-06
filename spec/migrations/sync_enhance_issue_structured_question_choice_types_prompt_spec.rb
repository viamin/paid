# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_enhance_issue_structured_question_choice_types_prompt.rb").sole

RSpec.describe SyncEnhanceIssueStructuredQuestionChoiceTypesPrompt, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: "goal.enhance_issue").destroy_all
    end
  end

  it "adds choice semantics to an existing structured-question prompt" do # @spec ISSUE-ENHANCEMENT-018
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    prompt.create_version!(template: "old template", variables: [], created_by: "seed")

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)
    expect(prompt.current_version.template).to include('"choice_type": "single"')
    expect(prompt.current_version.template).to include("set `choice_type` to `single`")
  end

  it "is idempotent once the current template is active" do # @spec ISSUE-ENHANCEMENT-020
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    prompt.create_version!(template: "old template", variables: [], created_by: "seed")

    migration.up

    expect { migration.up }.not_to change { prompt.reload.prompt_versions.count }
  end

  it "updates a prompt that has no current version" do # @spec ISSUE-ENHANCEMENT-020
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)
  end
end
