# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ResolveManualReview do
  let(:actor) { create(:user) }
  let(:project) { create(:project, account: actor.account, created_by: actor) }
  let(:issue) do
    create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      reopen_reason: "Live validation remains", github_updated_at: Time.current)
  end
  let(:created_run) { create(:agent_run, project:, issue:, goal: "create_pr", status: "queued") }
  let(:run_creator) { ->(goal:) { created_run.tap { |run| run.update!(goal:) } } }

  def resolve(**overrides)
    described_class.call(
      issue:, actor:, action: "record_reopen_decision",
      revision: issue.github_updated_at.iso8601, reason: "Prior closure lacked live evidence",
      continuation: "implementation", run_creator:, **overrides
    )
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records a revision-bound decision and resumes implementation" do
    expect { resolve }.to change(AccountActivityEvent, :count).by(1)

    expect(issue.reload.paid_state).to eq("in_progress")
    expect(AccountActivityEvent.last.metadata).to include(
      "decision" => "resume_implementation",
      "revision" => issue.github_updated_at.iso8601
    )
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "rejects a stale revision without clearing the hold" do
    result = resolve(revision: 1.day.ago.iso8601)

    expect(result).not_to be_success
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec OPERATOR-INBOX-002D
  it "does not let an acknowledgement waive a simultaneous dependency" do
    dependency = create(:issue, project:, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    result = resolve

    expect(result.message).to include("dependency")
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002D
  it "reuses compatible queued work without creating a second run" do
    active = created_run

    expect { resolve }.not_to change(AgentRun, :count)
    expect(issue.reload.paid_state).to eq("in_progress")
    expect(resolve(action: "record_reopen_decision").message).to include("no longer waiting")
    expect(active.reload.status).to eq("queued")
  end
end
