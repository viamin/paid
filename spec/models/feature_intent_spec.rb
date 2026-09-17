# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-004 @spec FEATURE-APPROVAL-005
RSpec.describe FeatureIntent do
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

    it "raises for a released feature intent" do
      feature_intent = create(:feature_intent, status: "released")
      approver = create(:user)

      expect { feature_intent.record_approval!(by: approver, pr_heads: {}) }
        .to raise_error(FeatureIntent::InvalidTransitionError)
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
  end
end
