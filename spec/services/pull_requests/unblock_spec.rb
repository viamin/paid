# frozen_string_literal: true

require "rails_helper"

RSpec.describe PullRequests::Unblock do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user, owner: "acme", repo: "alpha") }
  let(:github_client) { instance_double(GithubClient) }

  let(:pull_request) do
    create(:issue, :pull_request,
      project: project,
      github_number: 42,
      pr_review_phase: "escalated",
      pr_escalation_reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      labels: [ "paid-generated", "paid-automation", "paid-escalated" ],
      draft_review_count: 12,
      pr_followup_count: 4,
      review_goal_retry_count: 3,
      stuck_confirmation_count: 2)
  end

  before do
    allow(pull_request).to receive(:project).and_return(project)
    allow(project).to receive(:client).and_return(github_client)
    allow(github_client).to receive(:remove_label_from_issue)
  end

  # @spec PR-ESCALATION-014
  it "clears the escalation, strips the label on GitHub, and enqueues nothing" do
    expect {
      result = described_class.call(pull_request: pull_request)
      expect(result).to be_success
    }.not_to change(AgentRun, :count)

    pull_request.reload
    expect(pull_request.pr_review_phase).to eq("ready")
    expect(pull_request.pr_escalation_reason).to be_nil
    expect(pull_request.labels).not_to include("paid-escalated")
    expect(pull_request.draft_review_count).to eq(0)
    expect(pull_request.pr_followup_count).to eq(0)
    expect(pull_request.review_goal_retry_count).to eq(0)
    expect(pull_request.stuck_confirmation_count).to eq(0)
    expect(github_client).to have_received(:remove_label_from_issue)
      .with(project.full_name, 42, "paid-escalated")
  end

  # @spec PR-ESCALATION-014
  it "leaves an operator's auto-continue pause in place" do
    pull_request.update!(auto_continue_paused: true)

    described_class.call(pull_request: pull_request)

    expect(pull_request.reload.auto_continue_paused).to be(true)
    expect(pull_request.pr_review_phase).to eq("ready")
  end

  # @spec PR-ESCALATION-014
  it "applies the clearing under a row lock" do
    allow(pull_request).to receive(:with_lock).and_call_original

    described_class.call(pull_request: pull_request)

    expect(pull_request).to have_received(:with_lock)
  end

  # @spec PR-ESCALATION-015
  it "refuses to clear a pull request that is no longer open" do
    pull_request.update!(github_state: "closed")

    result = described_class.call(pull_request: pull_request)

    expect(result).not_to be_success
    expect(result.error).to eq(:not_open)
    pull_request.reload
    expect(pull_request.pr_review_phase).to eq("escalated")
    expect(pull_request.draft_review_count).to eq(12)
    expect(pull_request.pr_followup_count).to eq(4)
    expect(github_client).not_to have_received(:remove_label_from_issue)
  end

  # @spec PR-ESCALATION-016
  it "still clears locally when the GitHub label removal fails" do
    allow(github_client).to receive(:remove_label_from_issue).and_raise(GithubClient::ApiError.new("500 Internal Server Error"))
    allow(Rails.logger).to receive(:warn)

    result = described_class.call(pull_request: pull_request)

    expect(result).to be_success
    pull_request.reload
    expect(pull_request.pr_review_phase).to eq("ready")
    expect(pull_request.draft_review_count).to eq(0)
    expect(Rails.logger).to have_received(:warn)
      .with(hash_including(message: "pr_escalation.label_removal_failed"))
  end

  context "when the pull request is a draft" do
    before { pull_request.update!(pr_review_phase: "escalated") }

    # @spec PR-ESCALATION-014
    it "returns the pull request to the restarted phase" do
      described_class.call(pull_request: pull_request, draft: true)

      expect(pull_request.reload.pr_review_phase).to eq("restarted")
    end
  end

  context "when the escalation was a token-cap escalation" do
    before do
      pull_request.update!(pr_escalation_reason: Issue::PR_ESCALATION_REASON_PR_AUTO_CONTINUE_TOKEN_LIMIT)
    end

    # @spec PR-ESCALATION-014
    it "records the standing token-cap override" do
      freeze_time do
        described_class.call(pull_request: pull_request)

        expect(pull_request.reload.pr_auto_continue_token_limit_overridden_at)
          .to be_within(1.second).of(Time.current)
      end
    end
  end
end
