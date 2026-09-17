# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-004 @spec FEATURE-APPROVAL-005 @spec FEATURE-APPROVAL-007
RSpec.describe FeatureIntents::MarkApproved do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }
  let(:feature_intent) { create(:feature_intent, :ready_for_approval, project: project) }

  before { owner }

  it "records the actor, time, and exact design PR heads on a ready feature intent" do
    design_pr = create(:feature_intent_design_pr, feature_intent: feature_intent, pull_request_number: 42,
      head_sha: "c" * 40, reviewed_head_sha: "c" * 40)

    result = described_class.call(feature_intent: feature_intent, actor: owner)

    expect(result.status).to eq("approved_waiting_for_merge")
    expect(result.approved_by).to eq(owner)
    expect(result.approved_at).to be_present
    expect(result.approved_pr_heads).to eq({ design_pr.pull_request_number.to_s => "c" * 40 })
  end

  it "raises and does not approve when the actor lacks Inbox access" do
    other_account = create(:account)
    outsider = create(:user, account: other_account)

    expect { described_class.call(feature_intent: feature_intent, actor: outsider) }
      .to raise_error(FeatureIntents::MarkApproved::NotAuthorizedError)

    expect(feature_intent.reload.status).not_to eq("approved_waiting_for_merge")
  end

  it "raises with blockers and does not approve when the feature intent is not ready" do
    create(:feature_intent_decision, feature_intent: feature_intent, kind: "question")

    expect { described_class.call(feature_intent: feature_intent, actor: owner) }
      .to raise_error(FeatureIntents::MarkApproved::NotReadyError) { |error|
        expect(error.blockers.map(&:code)).to include("unresolved_questions")
      }

    expect(feature_intent.reload.status).not_to eq("approved_waiting_for_merge")
  end

  it "allows an account viewer with an explicit project role to approve" do
    viewer_with_project_role = create(:user, :viewer, account: account)
    viewer_with_project_role.add_role(:project_member, project)

    result = described_class.call(feature_intent: feature_intent, actor: viewer_with_project_role)

    expect(result.approved_by).to eq(viewer_with_project_role)
  end

  it "does not allow an account viewer without a project role to approve" do
    viewer = create(:user, :viewer, account: account)

    expect { described_class.call(feature_intent: feature_intent, actor: viewer) }
      .to raise_error(FeatureIntents::MarkApproved::NotAuthorizedError)
  end

  it "re-approves the current head after a stale approval is refreshed" do
    approved = create(:feature_intent, :approved_waiting_for_merge, project: project)
    design_pr = create(:feature_intent_design_pr, feature_intent: approved, pull_request_number: 7,
      head_sha: "d" * 40, reviewed_head_sha: "d" * 40)
    approved.update!(approved_pr_heads: { "7" => "c" * 40 })

    result = described_class.call(feature_intent: approved, actor: owner)

    expect(result.approved_pr_heads).to eq({ "7" => design_pr.head_sha })
  end
end
