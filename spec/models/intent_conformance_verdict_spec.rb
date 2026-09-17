# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-CONFORMANCE-001
# @spec INTENT-MERGE-GUARD-002
# @spec INTENT-MERGE-GUARD-003
# @spec INTENT-MERGE-GUARD-004
# @spec INTENT-CONFORMANCE-REVIEW-002
RSpec.describe IntentConformanceVerdict do
  describe "validations" do
    it "requires an outcome from the defined set" do
      verdict = build(:intent_conformance_verdict, outcome: "not_a_real_outcome")

      expect(verdict).not_to be_valid
      expect(verdict.errors[:outcome]).to be_present
    end

    it "requires a pr_head_sha, approved_design_revision, and evaluated_at" do
      verdict = build(:intent_conformance_verdict, pr_head_sha: nil, approved_design_revision: nil, evaluated_at: nil)

      expect(verdict).not_to be_valid
      expect(verdict.errors[:pr_head_sha]).to be_present
      expect(verdict.errors[:approved_design_revision]).to be_present
      expect(verdict.errors[:evaluated_at]).to be_present
    end
  end

  # @spec INTENT-CONFORMANCE-REVIEW-002
  it "requires reviewer identity evidence (model)" do
    verdict = build(:intent_conformance_verdict, reviewer_model: nil)

    expect(verdict).not_to be_valid
    expect(verdict.errors[:reviewer_model]).to be_present
  end

  describe ".current_for" do
    it "returns nil when head_sha is blank" do
      issue = create(:issue, :pull_request)

      expect(described_class.current_for(issue: issue, head_sha: nil)).to be_nil
    end

    it "returns nil when no verdict matches the given head" do
      issue = create(:issue, :pull_request)
      create(:intent_conformance_verdict, issue: issue, pr_head_sha: "old-sha")

      expect(described_class.current_for(issue: issue, head_sha: "current-sha")).to be_nil
    end

    it "returns the most recently evaluated verdict for the exact head" do
      issue = create(:issue, :pull_request)
      older = create(:intent_conformance_verdict, issue: issue, pr_head_sha: "current-sha", evaluated_at: 2.hours.ago)
      newer = create(:intent_conformance_verdict, issue: issue, pr_head_sha: "current-sha", evaluated_at: 1.minute.ago)
      create(:intent_conformance_verdict, issue: issue, pr_head_sha: "other-sha")

      expect(described_class.current_for(issue: issue, head_sha: "current-sha")).to eq(newer)
      expect(described_class.current_for(issue: issue, head_sha: "current-sha")).not_to eq(older)
    end
  end

  describe ".latest_for" do
    it "returns the most recently evaluated verdict for the issue" do
      issue = create(:issue, :pull_request)
      older = create(:intent_conformance_verdict, issue: issue, evaluated_at: 2.hours.ago)
      newer = create(:intent_conformance_verdict, issue: issue, evaluated_at: 1.minute.ago)

      expect(described_class.latest_for(issue)).to eq(newer)
      expect(described_class.latest_for(issue)).not_to eq(older)
    end

    it "returns nil when no verdict has been recorded" do
      issue = create(:issue, :pull_request)

      expect(described_class.latest_for(issue)).to be_nil
    end
  end

  describe "#current_for?" do
    it "matches only the exact head and approved design revision it was evaluated against" do
      verdict = build(:intent_conformance_verdict, pr_head_sha: "head0001", approved_design_revision: "rev1")

      expect(verdict.current_for?(pr_head_sha: "head0001", approved_design_revision: "rev1")).to be(true)
      expect(verdict.current_for?(pr_head_sha: "head0002", approved_design_revision: "rev1")).to be(false)
      expect(verdict.current_for?(pr_head_sha: "head0001", approved_design_revision: "rev2")).to be(false)
    end
  end

  describe "outcome predicates" do
    it "reflects the persisted outcome" do
      expect(build(:intent_conformance_verdict, :material_drift)).to be_material_drift
      expect(build(:intent_conformance_verdict, :uncertain)).to be_uncertain
      expect(build(:intent_conformance_verdict, :not_evaluated)).to be_not_evaluated
      expect(build(:intent_conformance_verdict)).to be_within_scope
    end
  end
end
