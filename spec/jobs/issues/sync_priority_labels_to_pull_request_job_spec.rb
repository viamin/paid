# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::SyncPriorityLabelsToPullRequestJob do
  let(:project) { create(:project, owner: "viamin", repo: "paid") }
  let(:issue) { create(:issue, project: project, labels: [ "P1" ]) }

  # @spec PRIORITY-LABEL-SYNC-005
  it "re-runs the reconciliation for the issue" do
    allow(Issues::SyncPriorityLabelsToPullRequest).to receive(:call!)

    described_class.perform_now(issue.id)

    expect(Issues::SyncPriorityLabelsToPullRequest).to have_received(:call!).with(issue: issue)
  end

  # @spec PRIORITY-LABEL-SYNC-005
  it "discards when the issue no longer exists" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end

  # @spec PRIORITY-LABEL-SYNC-005
  it "schedules a retry when the GitHub write fails transiently" do
    allow(Issues::SyncPriorityLabelsToPullRequest).to receive(:call!)
      .and_raise(GithubClient::ApiError.new("boom", status: 502))

    expect { described_class.perform_now(issue.id) }
      .to have_enqueued_job(described_class).with(issue.id)
  end
end
