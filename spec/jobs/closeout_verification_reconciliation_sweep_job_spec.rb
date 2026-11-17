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
end
