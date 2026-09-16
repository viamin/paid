# frozen_string_literal: true

require "rails_helper"

require Rails.root.glob("db/migrate/*_sync_enhance_issue_contextual_questions_prompt.rb").sole

RSpec.describe SyncEnhanceIssueContextualQuestionsPrompt, :aggregate_failures do
  let(:migration) { described_class.new }

  before do
    TenantContext.with_system_access do
      Prompt.unscoped.where(slug: "goal.enhance_issue").destroy_all
    end
  end

  # @spec ISSUE-ENHANCEMENT-014
  it "promotes the question-context contract for an existing structured-output prompt" do
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    previous_version = prompt.create_version!(
      template: "paid-enhance-issue-output\n{\"sufficient_context\": false, \"comment_body\": \"## Clarifying questions\"}\npaid-enhance-issue-output",
      variables: [],
      created_by: "seed"
    )

    expect { migration.up }.to change { prompt.reload.prompt_versions.count }.by(1)

    expect(prompt.current_version).not_to eq(previous_version)
    expect(prompt.current_version.template).to include("paid-enhance-issue-output")
    expect(prompt.current_version.template).to include("stands on its own")
    expect(prompt.current_version.template).to match(/why you are asking and what\s+you found in the repository/)
    expect(prompt.current_version.template).to include("Reference the relevant code, issue, or doc")
    expect(prompt.current_version.template).to include("name the options")
    expect(prompt.current_version.template).to include("where the issue sits in the roadmap")
    expect(prompt.current_version.created_by).to eq("migration")
  end

  # @spec ISSUE-ENHANCEMENT-014
  it "keeps the structured-output contract intact" do
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")

    migration.up

    template = prompt.reload.current_version.template
    expect(template).to include("paid-enhance-issue-output")
    expect(template).to include("sufficient_context")
    expect(template).to include("comment_body")
    expect(template).not_to include("POST $GITHUB_API_URL")
    expect(template).not_to include("/issues/{{issue_number}}/comments")
  end

  # @spec ISSUE-ENHANCEMENT-014
  it "is idempotent when the expected prompt version is active" do
    prompt = create(:prompt, :global, slug: "goal.enhance_issue", name: "Goal: Enhance Issue")
    migration.up

    expect { migration.up }.not_to change { prompt.reload.prompt_versions.count }
  end
end
