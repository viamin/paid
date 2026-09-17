# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-AMENDMENT-001
# @spec INTENT-AMENDMENT-002
RSpec.describe IntentResolutions::Record do
  let(:project) { create(:project) }
  let(:feature) { create(:feature_intent, project: project) }
  let(:pr_issue) { create(:issue, :pull_request, project: project) }
  let(:actor) { create(:user, account: project.account) }

  before do
    create(:feature_intent_issue, feature_intent: feature, issue: pr_issue)
    project.account.tenant_setting!.update!(features: { "approved_intent_amendments" => true })
  end

  it "records a bounded one-PR exception with actor, PR, head, and reason" do
    resolution = described_class.call(
      project: project,
      issue: pr_issue,
      pull_request_number: 42,
      pr_head_sha: "abc123",
      resolution_type: "implementation_exception",
      resolved_by: actor,
      reason: "Reviewer flagged the helper rename; the product contract is intact."
    )

    expect(resolution).to be_persisted
    expect(resolution.resolved_by).to eq(actor)
    expect(resolution.pr_head_sha).to eq("abc123")
    expect(resolution.product_contract_changed?).to be(false)
  end

  it "refuses to record an exception that changes a product commitment" do
    expect {
      described_class.call(
        project: project,
        issue: pr_issue,
        pull_request_number: 42,
        pr_head_sha: "abc123",
        resolution_type: "implementation_exception",
        resolved_by: actor,
        reason: "Behavior should change.",
        changes: { behavior: true }
      )
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "opens a design amendment when the human changes the product contract" do
    resolution = described_class.call(
      project: project,
      issue: pr_issue,
      pull_request_number: 42,
      pr_head_sha: "abc123",
      resolution_type: "design_amendment",
      resolved_by: actor,
      reason: "The acceptance criteria must change.",
      changes: { acceptance_criteria: true }
    )

    expect(resolution.design_amendment).to be_present
    expect(resolution.design_amendment.feature_intent).to eq(feature)
    expect(resolution.design_amendment.superseded_revision).to eq(feature.approved_design_revision)
    expect(feature.reload).to be_revising
  end

  it "links an existing amendment when one is supplied" do
    opened = DesignAmendments::Open.call(
      feature_intent: feature,
      reason: "Scope must widen."
    )

    resolution = described_class.call(
      project: project,
      issue: pr_issue,
      pull_request_number: 42,
      pr_head_sha: "abc123",
      resolution_type: "design_amendment",
      resolved_by: actor,
      reason: "Scope should widen.",
      changes: { scope: true },
      design_amendment: opened
    )

    expect(resolution.design_amendment).to eq(opened)
    expect(DesignAmendment.count).to eq(1)
  end

  it "cannot record a product-contract amendment for an issue outside the feature tree" do
    orphan_pr = create(:issue, :pull_request, project: project)

    expect {
      described_class.call(
        project: project,
        issue: orphan_pr,
        pull_request_number: 43,
        pr_head_sha: "def456",
        resolution_type: "design_amendment",
        resolved_by: actor,
        reason: "No feature intent links this PR.",
        changes: { scope: true }
      )
    }.to raise_error(ArgumentError, /no feature intent/)
  end
end
