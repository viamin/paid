# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_enhance_issue_choice_markers_prompt.rb").sole

RSpec.describe SyncEnhanceIssueChoiceMarkersPrompt, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: "goal.enhance_issue").destroy_all
    end
  end

  # @spec ISSUE-ENHANCEMENT-018
  it "promotes the choice-marker option syntax for an existing prompt" do
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    previous_version = prompt.create_version!(
      template: "paid-enhance-issue-output\n{\"sufficient_context\": false, \"comment_body\": \"## Clarifying questions\"}\npaid-enhance-issue-output",
      variables: [],
      created_by: "seed"
    )

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)

    expect(prompt.current_version).not_to eq(previous_version)
    expect(prompt.current_version.template).to include("paid-enhance-issue-output")
    expect(prompt.current_version.template).to include("Choice questions")
    expect(prompt.current_version.template).to include("- ( ) SQLite) local file, zero setup")
    expect(prompt.current_version.template).to include("- ( ) Postgres) already used for app data")
    expect(prompt.current_version.template).to include("`- ( ) Label) description` lines when exactly one answer applies")
    expect(prompt.current_version.template).to include("`- [ ] Label) description` lines when several answers may apply")
    expect(prompt.current_version.template).to match(/Provide at least two\s+option lines/)
    expect(prompt.current_version.created_by).to eq("migration")
  end

  # @spec ISSUE-ENHANCEMENT-018
  it "keeps the structured-output and question-context contracts intact" do
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")

    migration.up

    template = prompt.reload.current_version.template
    expect(template).to include("paid-enhance-issue-output")
    expect(template).to include("sufficient_context")
    expect(template).to include("comment_body")
    expect(template).to include("stands on its own")
    expect(template).to include("name the options")
    expect(template).not_to include("POST $GITHUB_API_URL")
    expect(template).not_to include("/issues/{{issue_number}}/comments")
  end

  # @spec ISSUE-ENHANCEMENT-018
  it "is idempotent when the expected prompt version is active" do
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    migration.up

    expect { migration.up }.not_to change { prompt.reload.prompt_versions.count }
  end

  # @spec ISSUE-ENHANCEMENT-018
  it "carries the same template as the code fallback" do
    expect(described_class::TEMPLATE.strip)
      .to eq(Activities::RunAgentActivity::FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT.strip)
  end
end
