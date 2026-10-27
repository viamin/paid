# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-008
RSpec.describe WorkItemContinuationGrant do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }

  it "covers the starting phase and the later delivery phases through the endpoint" do
    grant = build(:work_item_continuation_grant, start_phase: "issue_preparation", endpoint: "merge")

    expect(grant.covered_phases).to eq(%w[issue_preparation coding merge])
  end

  it "never covers discovery, release, or operations" do
    grant = build(:work_item_continuation_grant, start_phase: "coding", endpoint: "merge")

    expect(grant.covered_phases).not_to include("discovery", "release_deployment", "operations")
  end

  it "rejects an endpoint that precedes the starting phase" do
    grant = build(:work_item_continuation_grant, start_phase: "merge", endpoint: "coding")

    expect(grant).not_to be_valid
    expect(grant.errors[:endpoint]).to be_present
  end

  it "rejects an unsupported source" do
    grant = build(:work_item_continuation_grant, source: "deployment_engine")

    expect(grant).not_to be_valid
  end

  # @spec AUTOMATION-PHASES-005 @spec AUTOMATION-PHASES-009
  it "requires the work item and author to belong to the grant project account" do
    other_project = create(:project, account: create(:account))
    outside_actor = create(:user, account: other_project.account)

    wrong_work_item = build(
      :work_item_continuation_grant,
      project:,
      issue: create(:issue, project: other_project),
      created_by: user
    )
    wrong_actor = build(:work_item_continuation_grant, project:, issue:, created_by: outside_actor)
    missing_actor = build(:work_item_continuation_grant, project:, issue:, created_by: nil)

    expect(wrong_work_item).not_to be_valid
    expect(wrong_work_item.errors[:issue]).to include("must belong to the grant project")
    expect(wrong_actor).not_to be_valid
    expect(wrong_actor.errors[:created_by]).to include("must belong to the grant project account")
    expect(missing_actor).not_to be_valid
    expect(missing_actor.errors[:created_by]).to include("can't be blank")
  end

  describe "completion" do
    it "completes when the endpoint's work lands" do
      grant = create(:work_item_continuation_grant, project:, issue:)

      expect(grant.complete!).to be(true)
      expect(grant.reload).to be_completed
    end

    it "does not reactivate when work is reopened" do
      grant = create(:work_item_continuation_grant, project:, issue:)
      grant.complete!

      expect(grant.complete!).to be(false)
      expect(grant.reload).to be_completed
    end

    # @spec AUTOMATION-PHASES-008
    it "completes a merge grant when its linked pull request merges" do
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue, pr_review_phase: "ready")
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      pull_request.update!(github_state: "closed", pr_review_phase: "merged")

      expect(grant.reload).to be_completed
    end

    it "completes earlier endpoint grants when linked work reaches merge" do
      pull_request = create(:issue, :pull_request, project:, parent_issue: issue, pr_review_phase: "ready")
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "coding")

      Automation::CompleteContinuationGrants.call(work_items: pull_request, endpoint: "merge")

      expect(grant.reload).to be_completed
    end
  end

  describe "revocation" do
    it "records the revoking user and withdrawal" do
      grant = create(:work_item_continuation_grant, project:, issue:)

      grant.revoke!(user:)

      expect(grant.reload.revoked_at).to be_present
      expect(grant.revoked_by).to eq(user)
    end

    it "does not revoke an already completed grant" do
      grant = create(:work_item_continuation_grant, project:, issue:)
      grant.complete!

      expect(grant.revoke!(user:)).to be(false)
    end
  end

  describe "active scope" do
    it "excludes revoked and completed grants" do
      active = create(:work_item_continuation_grant, project:, issue:)
      revoked = create(:work_item_continuation_grant, project:, issue:)
      revoked.revoke!(user:)
      completed = create(:work_item_continuation_grant, project:, issue:)
      completed.complete!

      expect(described_class.active).to contain_exactly(active)
    end
  end
end
