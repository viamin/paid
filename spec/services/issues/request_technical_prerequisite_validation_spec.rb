# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::RequestTechnicalPrerequisiteValidation do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "in_progress") }

  # @spec PARTIAL-CLOSEOUT-030
  it "queues one bounded validation continuation" do
    create(:issue, :pull_request, project:, github_state: "closed", pr_review_phase: "merged", parent_issue: issue)

    result = described_class.call(issue:, actor: user)

    expect(result).to be_success
    expect(result.agent_run.goal).to eq("analyze_issue")
    expect(result.request.evidence).to include("continuation_mode" => "technical_prerequisite_validation")
  end
end
