# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-009 @spec FEATURE-APPROVAL-010 @spec FEATURE-APPROVAL-020 @spec CONFIDENCE-DELIVERY-001 @spec CONFIDENCE-DELIVERY-015
RSpec.describe FeatureIntent do
  describe "delivery policy" do
    it "defaults existing and newly created records to the approval-gated policy" do
      expect(described_class.new.delivery_policy).to eq("approval_gated")
    end

    it "keeps a confidence-driven policy snapshot after project enrollment is disabled" do
      feature_intent = create(:feature_intent, :confidence_driven)

      feature_intent.project.update!(confidence_delivery_enrollment_enabled: false)

      expect(feature_intent.reload.delivery_policy).to eq("confidence_driven")
    end

    it "does not mutate held work or active runs when enrollment is disabled" do
      project = create(:project, confidence_delivery_enrollment_enabled: true)
      held_issue = create(:issue, :needs_input, project: project)
      active_run = create(:agent_run, project: project, status: "running")
      feature_intent = create(:feature_intent, :confidence_driven, project: project)

      expect {
        project.update!(confidence_delivery_enrollment_enabled: false)
      }.not_to change(AgentRun, :count)

      expect(held_issue.reload.paid_state).to eq("needs_input")
      expect(active_run.reload.status).to eq("running")
      expect(feature_intent.reload).to be_confidence_driven
    end
  end

  describe "#record_approval!" do
    it "transitions design_open to approved_waiting_for_merge and stamps the approval" do
      feature_intent = create(:feature_intent, :ready_for_approval)
      approver = create(:user)

      feature_intent.record_approval!(by: approver, pr_heads: { "1" => "a" * 40 })

      expect(feature_intent.status).to eq("approved_waiting_for_merge")
      expect(feature_intent.approved_by).to eq(approver)
      expect(feature_intent.approved_at).to be_present
      expect(feature_intent.approved_pr_heads).to eq({ "1" => "a" * 40 })
    end

    it "allows re-approving an already approved_waiting_for_merge feature intent" do
      feature_intent = create(:feature_intent, :approved_waiting_for_merge)
      approver = create(:user)

      expect { feature_intent.record_approval!(by: approver, pr_heads: { "1" => "b" * 40 }) }.not_to raise_error
      expect(feature_intent.approved_pr_heads).to eq({ "1" => "b" * 40 })
    end

    it "appends an immutable approval revision for each approval" do
      feature_intent = create(:feature_intent, :ready_for_approval)
      first_approver = create(:user)
      second_approver = create(:user)

      feature_intent.record_approval!(by: first_approver, pr_heads: { "1" => "a" * 40 })
      feature_intent.record_approval!(by: second_approver, pr_heads: { "1" => "b" * 40 })

      expect(feature_intent.feature_intent_approval_revisions.pluck(:approved_by_id, :pr_heads)).to eq(
        [ [ first_approver.id, { "1" => "a" * 40 } ], [ second_approver.id, { "1" => "b" * 40 } ] ]
      )
    end

    it "does not permit an approval revision to be changed" do
      feature_intent = create(:feature_intent, :ready_for_approval)
      feature_intent.record_approval!(by: create(:user), pr_heads: {})

      expect { feature_intent.feature_intent_approval_revisions.first.update!(source: "changed") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "raises for a released feature intent" do
      feature_intent = create(:feature_intent, status: "released")
      approver = create(:user)

      expect { feature_intent.record_approval!(by: approver, pr_heads: {}) }
        .to raise_error(FeatureIntent::InvalidTransitionError)
    end

    it "rejects approval when the feature is released after it was loaded" do
      feature_intent = create(:feature_intent, :approved_waiting_for_merge)
      approver = create(:user)

      described_class.where(id: feature_intent.id).update_all(status: "released")

      expect { feature_intent.record_approval!(by: approver, pr_heads: {}) }
        .to raise_error(FeatureIntent::InvalidTransitionError)
      expect(feature_intent.feature_intent_approval_revisions).to be_empty
    end

    it "raises for a cancelled feature intent" do
      feature_intent = create(:feature_intent, status: "cancelled")
      approver = create(:user)

      expect { feature_intent.record_approval!(by: approver, pr_heads: {}) }
        .to raise_error(FeatureIntent::InvalidTransitionError)
    end
  end

  describe "validations" do
    it "requires a known criteria_clarity_state" do
      feature_intent = build(:feature_intent, criteria_clarity_state: "maybe")

      expect(feature_intent).not_to be_valid
    end

    # @spec FEATURE-APPROVAL-020
    it "only permits http(s) replacement references" do
      feature_intent = build(:feature_intent, replacement_reference: "javascript:alert(1)")

      expect(feature_intent).not_to be_valid
      expect(feature_intent.errors[:replacement_reference]).to include("must be an http(s) URL")
    end
  end
end
