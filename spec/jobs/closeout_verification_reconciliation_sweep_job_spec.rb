# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerificationReconciliationSweepJob do
  # @spec STAGED-CLOSEOUT-ADOPTION-009
  it "retries only persisted merged PR observations in a bounded sweep" do
    project = create(:project)
    merged = create(:issue, :pull_request, project:, pr_review_phase: "merged", merged_commit_sha: "a" * 40)
    create(:issue, :pull_request, project:, pr_review_phase: "ready", merged_commit_sha: "b" * 40)

    expect(CloseoutVerifications::Admit).to receive(:call).with(source_pr: merged, merge_commit_sha: "a" * 40)

    described_class.new.perform
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-009
  it "continues beyond the per-project pull request batch" do
    stub_const("#{described_class}::PULL_REQUEST_BATCH_SIZE", 1)
    project = create(:project)
    first = create(:issue, :pull_request, project:, pr_review_phase: "merged", merged_commit_sha: "a" * 40)
    second = create(:issue, :pull_request, project:, pr_review_phase: "merged", merged_commit_sha: "b" * 40)

    expect(CloseoutVerifications::Admit).to receive(:call).with(source_pr: first, merge_commit_sha: "a" * 40)
    expect {
      described_class.new.perform(project_id: project.id)
    }.to have_enqueued_job(described_class).with(project_id: project.id, after_pull_request_id: first.id)

    expect(CloseoutVerifications::Admit).to receive(:call).with(source_pr: second, merge_commit_sha: "b" * 40)
    described_class.new.perform(project_id: project.id, after_pull_request_id: first.id)
  end
end
