# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::EvaluateNotificationRulesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:pr) { create(:issue, :pull_request, project: project) }

  it "routes the batch to the rule services" do
    allow(Notifications::Rules::RepeatedNoChanges).to receive(:call)
    allow(Notifications::Rules::StalledDraftPr).to receive(:call)
    allow(Notifications::Rules::PrFollowupLimitReached).to receive(:call)
    allow(Notifications::Rules::ScannerWedgedOnPendingReview).to receive(:call)

    activity.execute(
      project_id: project.id,
      issue_ids: [ issue.id, pr.id ],
      pr_issue_ids: [ pr.id ],
      pending_review_states: [ { issue_id: pr.id, pending_review: true, requested_bot: "copilot", pr_phase: "draft" } ],
      pr_progress_states: [ { issue_id: pr.id, consecutive_unsuccessful_automatic_runs: 1 } ]
    )

    expect(Notifications::Rules::RepeatedNoChanges).to have_received(:call)
    expect(Notifications::Rules::StalledDraftPr).to have_received(:call)
    expect(Notifications::Rules::PrFollowupLimitReached).to have_received(:call).with(
      scope: kind_of(ActiveRecord::Relation),
      progress_states: [ { issue_id: pr.id, consecutive_unsuccessful_automatic_runs: 1 } ]
    )
    expect(Notifications::Rules::ScannerWedgedOnPendingReview).to have_received(:call)
  end
end
