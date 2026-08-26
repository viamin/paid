# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-005
# @spec CHAT-API-011
RSpec.describe PullRequests::AutoMergeStatus do
  subject(:status) { described_class.call(issue:, project:) }

  let(:account) { create(:account) }
  let(:project) do
    create(:project,
      account: account,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin")
  end
  let(:issue) { create(:issue, :pull_request, project: project) }

  it "reports a stale approval blocker from the persisted snapshot" do
    persist_auto_merge_snapshot!(
      failed: [ stale_approval_blocker ],
      not_evaluated: [ dependency_not_evaluated_blocker ]
    )

    expect(status).to eq(
      last_auto_merge_attempt_at: nil,
      auto_merge_status: "blocked",
      reason_code: "stale_approval",
      sanitized_message: "The owner approval is stale for the current HEAD commit.",
      credential_mode: "personal_access_token",
      merge_permission_rejected: false,
      cooldown_until: nil,
      next_action: "Ask @viamin to re-approve this pull request for the current HEAD commit, then wait for the next automatic merge evaluation.",
      blockers: [ stale_approval_blocker ]
    )
  end

  it "reports all failed blockers and omits short-circuited checks from blockers" do
    persist_auto_merge_snapshot!(
      failed: [ owner_approval_blocker, checks_not_green_blocker ],
      not_evaluated: [ dependency_not_evaluated_blocker ]
    )

    expect(status.fetch(:auto_merge_status)).to eq("blocked")
    expect(status.fetch(:blockers)).to eq(issue.auto_merge_blockers.fetch("failed"))
  end

  it "reports merged ahead of a stale merge-permission rejection" do
    issue.update!(
      pr_review_phase: "merged",
      github_state: "closed",
      merge_permission_rejected_at: 2.hours.ago,
      merge_permission_rejection_reason: "missing workflows permission"
    )

    expect(status).to include(
      auto_merge_status: "merged",
      merge_permission_rejected: false,
      next_action: "No action required."
    )
  end

  it "reports a persisted merge-permission rejection ahead of blocker snapshots" do
    issue.update!(
      merge_permission_rejected_at: Time.current,
      merge_permission_rejection_reason: "missing workflows permission",
      auto_merge_blockers: snapshot_hash(failed: [ stale_approval_blocker ], not_evaluated: []),
      auto_merge_evaluated_at: Time.current
    )

    expect(status).to include(
      auto_merge_status: "blocked",
      merge_permission_rejected: true
    )
    expect(status.fetch(:reason_code)).not_to eq("stale_approval")
  end

  def persist_auto_merge_snapshot!(failed:, not_evaluated:)
    issue.update!(
      auto_merge_blockers: snapshot_hash(failed:, not_evaluated:),
      auto_merge_evaluated_at: Time.current
    )
  end

  def snapshot_hash(failed:, not_evaluated:)
    {
      "failed" => failed,
      "not_evaluated" => not_evaluated
    }
  end

  def stale_approval_blocker
    blocker(
      signal: "reviews_fresh",
      status: "failed",
      reason_code: "stale_approval",
      sanitized_message: "The owner approval is stale for the current HEAD commit.",
      next_action: "Ask @viamin to re-approve this pull request for the current HEAD commit, then wait for the next automatic merge evaluation."
    )
  end

  def dependency_not_evaluated_blocker
    blocker(
      signal: "dependencies_resolved",
      status: "not_evaluated",
      reason_code: "dependencies_unresolved",
      sanitized_message: "Dependency resolution was not evaluated because an earlier auto-merge gate already failed.",
      next_action: "Resolve the earlier auto-merge blockers first, then let Paid re-evaluate dependency resolution."
    )
  end

  def owner_approval_blocker
    blocker(
      signal: "owner_approved",
      status: "failed",
      reason_code: "owner_approval_missing",
      sanitized_message: "The required owner approval is missing.",
      next_action: "Ask @viamin to approve this pull request, then wait for the next automatic merge evaluation."
    )
  end

  def checks_not_green_blocker
    blocker(
      signal: "checks_green",
      status: "failed",
      reason_code: "checks_not_green",
      sanitized_message: "Required checks are not green yet.",
      next_action: "Wait for required checks to pass, then let auto-merge evaluate the pull request again."
    )
  end

  def blocker(signal:, status:, reason_code:, sanitized_message:, next_action:)
    {
      "signal" => signal,
      "status" => status,
      "reason_code" => reason_code,
      "sanitized_message" => sanitized_message,
      "next_action" => next_action
    }
  end
end
