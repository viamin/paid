# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-004 @spec INTENT-CONFORMANCE-005
RSpec.describe IntentConformanceDecision do
  describe "validations" do
    it "requires an action from the defined set" do
      decision = build(:intent_conformance_decision, action: "not_a_real_action")

      expect(decision).not_to be_valid
      expect(decision.errors[:action]).to be_present
    end

    it "requires a head_sha and reason" do
      decision = build(:intent_conformance_decision, head_sha: nil, reason: nil)

      expect(decision).not_to be_valid
      expect(decision.errors[:head_sha]).to be_present
      expect(decision.errors[:reason]).to be_present
    end
  end

  describe ".active_bounded_exception?" do
    it "is false when head_sha is blank" do
      issue = create(:issue, :pull_request)

      expect(described_class.active_bounded_exception?(issue: issue, head_sha: nil)).to be(false)
    end

    it "is false when no bounded_exception decision matches the head" do
      issue = create(:issue, :pull_request)
      create(:intent_conformance_decision, :bounded_exception, issue: issue, head_sha: "old-sha")

      expect(described_class.active_bounded_exception?(issue: issue, head_sha: "new-sha")).to be(false)
    end

    it "is false for a fix_pr or design_amendment decision on the same head" do
      issue = create(:issue, :pull_request)
      create(:intent_conformance_decision, issue: issue, head_sha: "current-sha")
      create(:intent_conformance_decision, :design_amendment, issue: issue, head_sha: "current-sha")

      expect(described_class.active_bounded_exception?(issue: issue, head_sha: "current-sha")).to be(false)
    end

    it "is true when a bounded_exception decision matches the exact head" do
      issue = create(:issue, :pull_request)
      create(:intent_conformance_decision, :bounded_exception, issue: issue, head_sha: "current-sha")

      expect(described_class.active_bounded_exception?(issue: issue, head_sha: "current-sha")).to be(true)
    end
  end
end
