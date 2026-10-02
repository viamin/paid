# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-015 @spec FEATURE-APPROVAL-016
RSpec.describe FeatureIntents::Release do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:approver) { create(:user, account: account) }
  let(:source) { "admission_reconciliation" }
  let(:feature_intent) { create(:feature_intent, :approved_waiting_for_merge, project: project, approved_design_revision: nil) }

  before do
    create(:feature_intent_design_pr, feature_intent:, pull_request_number: 42,
      head_sha: "a" * 40, reviewed_head_sha: "a" * 40, merged_at: Time.current)
    feature_intent.update!(status: "ready_for_approval")
    feature_intent.record_approval!(by: approver, pr_heads: { "42" => "a" * 40 })
  end

  it "releases only when every required design PR merged at the approved heads" do
    described_class.call(
      feature_intent:,
      merged_revision: "b" * 40,
      actor: approver,
      source: source
    )

    expect(feature_intent.reload).to have_attributes(status: "released", approved_design_revision: "b" * 40)
    expect(account.account_activity_events.last).to have_attributes(action: "feature_intent.released", actor: approver)
    expect(account.account_activity_events.last.metadata).to include(
      "source" => source,
      "from_status" => "approved_waiting_for_merge",
      "to_status" => "released"
    )
  end

  it "rejects release while a required design PR is unmerged" do
    feature_intent.feature_intent_design_prs.first.update!(merged_at: nil)

    expect { described_class.call(feature_intent:, merged_revision: "b" * 40, actor: approver, source:) }
      .to raise_error(described_class::NotReadyError, /required design PRs/)

    expect(feature_intent.reload.status).to eq("approved_waiting_for_merge")
  end

  it "rejects release when a design PR head changed after approval" do
    feature_intent.feature_intent_design_prs.first.update!(head_sha: "c" * 40)

    expect { described_class.call(feature_intent:, merged_revision: "b" * 40, actor: approver, source:) }
      .to raise_error(described_class::NotReadyError, /approval is stale/)
  end

  it "rejects release without a merged repository revision" do
    expect { described_class.call(feature_intent:, merged_revision: "", actor: approver, source:) }
      .to raise_error(described_class::NotReadyError, /merged repository revision/)

    expect(feature_intent.reload).to have_attributes(
      status: "approved_waiting_for_merge",
      approved_design_revision: nil
    )
  end
end
