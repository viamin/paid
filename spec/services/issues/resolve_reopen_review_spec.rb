# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ResolveReopenReview do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) do
    create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      title: "Collect the live validation artifacts",
      body: "Record the analyzer stdout, stderr and exit code.")
  end
  let(:revision) { Issue.reopen_review_revision_for(title: issue.title, body: issue.body) }

  def resolve(**overrides)
    described_class.call(
      issue:,
      actor: user,
      decision: "intent_valid",
      reason: "The validation artifacts are still required.",
      revision:,
      **overrides
    )
  end

  describe "recording the decision" do
    # @spec MANUAL-REVIEW-RECOVERY-002
    it "records the decision, the operator, the reason and the reviewed revision" do
      result = resolve

      expect(result).to be_success
      expect(issue.reload).to have_attributes(
        reopen_review_decision: "intent_valid",
        reopen_review_reason: "The validation artifacts are still required.",
        reopen_review_decided_by_id: user.id
      )
      expect(issue.reopen_review_decided_at).to be_present
      expect(issue.reopen_review_revision).to eq(revision)
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "releases the reopen gate so the supported continuation can be offered" do
      expect(issue).to be_reopen_review_pending

      resolve

      expect(issue.reload).not_to be_reopen_review_pending
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "records the decision in the account audit trail" do
      resolve

      event = account.account_activity_events.order(:id).last

      expect(event.action).to eq("issue.reopen_review_decided")
      expect(event.actor_id).to eq(user.id)
      expect(event.metadata["decision"]).to eq("intent_valid")
    end
  end

  describe "refusals" do
    # @spec MANUAL-REVIEW-RECOVERY-002
    it "refuses a decision made against a different revision of the scope" do
      reviewed_revision = revision
      issue.update!(body: "The scope changed after the review was opened.")

      result = resolve(revision: reviewed_revision)

      expect(result).not_to be_success
      expect(result.code).to eq(:stale_revision)
      expect(issue.reload.reopen_review_decision).to be_nil
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "refuses a decision without a reason" do
      result = resolve(reason: "  ")

      expect(result).not_to be_success
      expect(result.code).to eq(:invalid_reason)
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "refuses an unknown decision" do
      result = resolve(decision: "maybe")

      expect(result).not_to be_success
      expect(result.code).to eq(:invalid_decision)
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "refuses a decision without the reviewed revision" do
      result = resolve(revision: "")

      expect(result).not_to be_success
      expect(result.code).to eq(:invalid_revision)
    end

    # @spec MANUAL-REVIEW-RECOVERY-007
    it "refuses a second decision" do
      resolve

      result = resolve

      expect(result).not_to be_success
      expect(result.code).to eq(:already_decided)
      expect(issue.reload.reopen_review_decision).to eq("intent_valid")
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "refuses an issue that is not waiting for a reopen review" do
      issue.update!(manual_review_reason: "Round limit reached.")

      result = resolve

      expect(result).not_to be_success
      expect(result.code).to eq(:not_in_reopen_review)
    end

    # @spec MANUAL-REVIEW-RECOVERY-007
    it "refuses a stale caller after the issue has left manual review" do
      issue.update!(paid_state: "in_progress")

      result = resolve

      expect(result).not_to be_success
      expect(result.code).to eq(:not_in_reopen_review)
      expect(issue.reload.reopen_review_decision).to be_nil
    end

    # @spec MANUAL-REVIEW-RECOVERY-007
    it "refuses an actor from another account" do
      outsider = create(:user, account: create(:account))

      result = resolve(actor: outsider)

      expect(result).not_to be_success
      expect(result.code).to eq(:not_authorized)
      expect(issue.reload.reopen_review_decision).to be_nil
    end
  end

  describe "remaining holds" do
    # @spec MANUAL-REVIEW-RECOVERY-003
    it "keeps the issue parked on an unresolved dependency and does not waive it" do
      dependency = create(:issue, project:, github_number: 4321)
      create(:issue_dependency, issue:, depends_on_issue: dependency)

      result = resolve

      expect(result).to be_success
      expect(issue.reload.paid_state).to eq("manual_review")
      expect(issue.manual_review_reason).to include(Issue::DEPENDENCY_BLOCKED_REASON_MARKER)
      expect(issue.manual_review_reason).to include("#4321")
      expect(issue.reopen_review_decision).to eq("intent_valid")
    end
  end
end
