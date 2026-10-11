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

  # retry_on handles GithubClient::Error before ApplicationJob's rescue_from
  # callback. The exhausted retry handler must therefore retain the issue's
  # account and project while reporting the terminal failure.
  # @spec PRIORITY-LABEL-SYNC-005
  it "reports an exhausted retry to the issue account" do
    notifier = instance_double(Paid::ExceptionNotifier)
    allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
    allow(notifier).to receive(:call)
    allow(Issues::SyncPriorityLabelsToPullRequest).to receive(:call!)
      .and_raise(GithubClient::ApiError.new("boom", status: 502))

    job = described_class.new(issue.id)
    job.exception_executions = { "[GithubClient::Error]" => 7 }

    expect { job.perform_now }.to raise_error(GithubClient::ApiError, "boom")
    expect(notifier).to have_received(:call).with(
      an_instance_of(GithubClient::ApiError),
      data: hash_including(account: project.account, project_id: project.id)
    )
  end
end
