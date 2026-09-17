# frozen_string_literal: true

require "rails_helper"

# @spec INTENT-MERGE-GUARD-002
# @spec INTENT-MERGE-GUARD-003
# @spec INTENT-MERGE-GUARD-004
# @spec INTENT-CONFORMANCE-REVIEW-002
RSpec.describe IntentConformanceVerdict do
  it "is valid with an identity and a terminal outcome" do
    verdict = build(:intent_conformance_verdict)

    expect(verdict).to be_valid
  end

  it "requires a terminal outcome" do
    verdict = build(:intent_conformance_verdict, outcome: "approved")

    expect(verdict).not_to be_valid
    expect(verdict.errors[:outcome]).to be_present
  end

  # @spec INTENT-CONFORMANCE-REVIEW-002
  it "requires reviewer identity evidence (run id and model)" do
    verdict = build(:intent_conformance_verdict, reviewer_run_id: nil, reviewer_model: nil)

    expect(verdict).not_to be_valid
    expect(verdict.errors[:reviewer_run_id]).to be_present
    expect(verdict.errors[:reviewer_model]).to be_present
  end

  # @spec INTENT-CONFORMANCE-REVIEW-002
  it "requires an approved design revision" do
    verdict = build(:intent_conformance_verdict, approved_design_revision: nil)

    expect(verdict).not_to be_valid
    expect(verdict.errors[:approved_design_revision]).to be_present
  end

  # @spec INTENT-CONFORMANCE-REVIEW-002
  it "requires a PR head SHA" do
    verdict = build(:intent_conformance_verdict, pr_head_sha: nil)

    expect(verdict).not_to be_valid
    expect(verdict.errors[:pr_head_sha]).to be_present
  end

  # @spec INTENT-CONFORMANCE-REVIEW-002
  it "requires a recorded_at timestamp" do
    verdict = build(:intent_conformance_verdict, recorded_at: nil)

    expect(verdict).not_to be_valid
    expect(verdict.errors[:recorded_at]).to be_present
  end

  describe ".current_for" do
    it "returns the most recently recorded verdict for the issue" do
      issue = create(:issue, :pull_request)
      older = create(:intent_conformance_verdict, issue: issue, recorded_at: 2.hours.ago)
      newer = create(:intent_conformance_verdict, issue: issue, recorded_at: 1.minute.ago)

      expect(described_class.current_for(issue)).to eq(newer)
      expect(described_class.current_for(issue)).not_to eq(older)
    end

    it "returns nil when no verdict has been recorded" do
      issue = create(:issue, :pull_request)

      expect(described_class.current_for(issue)).to be_nil
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
    it "reflects the recorded outcome" do
      expect(build(:intent_conformance_verdict, outcome: "within_scope")).to be_within_scope
      expect(build(:intent_conformance_verdict, outcome: "material_drift")).to be_material_drift
      expect(build(:intent_conformance_verdict, outcome: "uncertain")).to be_uncertain
      expect(build(:intent_conformance_verdict, outcome: "not_evaluated")).to be_not_evaluated
    end
  end
end
