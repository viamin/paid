# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::Rules::InterruptedPullRequestPublication do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:source) { create(:issue, project: project, github_number: 41) }
  let(:pull_request) do
    create(:issue, :pull_request, project: project, github_number: 42,
      parent_issue: source, pr_review_phase: "draft")
  end

  it "surfaces an unrecorded failed publication as one actionable request" do # @spec PR-LABEL-RECOVERY-003
    run = create(:agent_run, :failed, project: project, issue: source, goal: "create_pr", pull_request_number: nil)

    expect(described_class.candidates(project)).to contain_exactly(pull_request)

    expect {
      described_class.call(scope: described_class.candidates(project))
    }.to change(Notification, :count).by(1)

    notification = Notification.find_by!(source: "interrupted_pull_request_publication", subject: pull_request)
    expect(notification).to be_blocking
    expect(notification.metadata).to include("agent_run_id" => run.id, "agent_run_status" => "failed")

    described_class.call(scope: described_class.candidates(project))
    expect(Notification.where(source: "interrupted_pull_request_publication", subject: pull_request).count).to eq(1)
  end

  it "waits for an active responsible workflow instead of creating a human task" do # @spec PR-LABEL-RECOVERY-003
    create(:agent_run, :failed, project: project, issue: source, goal: "create_pr", pull_request_number: nil)
    create(:agent_run, :running, project: project, issue: source, goal: "create_pr")

    expect {
      described_class.call(scope: described_class.candidates(project))
    }.not_to change(Notification, :count)
  end

  it "resolves the request when the PR closes" do # @spec PR-LABEL-RECOVERY-003
    create(:agent_run, :failed, project: project, issue: source, goal: "create_pr", pull_request_number: nil)
    described_class.call(scope: described_class.candidates(project))
    pull_request.update!(github_state: "closed")

    described_class.call(scope: [ pull_request ])

    expect(Notification.where(source: "interrupted_pull_request_publication", subject: pull_request)).to be_empty
  end
end
