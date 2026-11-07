# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe DelegationIntentCheckpoint do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }

  describe "validations" do
    it "is valid from the factory" do
      expect(build(:delegation_intent_checkpoint, project: project, issue: issue)).to be_valid
    end

    it "rejects an unknown status" do
      checkpoint = build(:delegation_intent_checkpoint, project: project, issue: issue, status: "finalized")
      expect(checkpoint).not_to be_valid
      expect(checkpoint.errors[:status]).to be_present
    end

    it "rejects an empty question group set and a mismatched issue" do
      empty = build(:delegation_intent_checkpoint, project: project, issue: issue, question_groups: [])
      expect(empty).not_to be_valid

      foreign_issue = create(:issue)
      mismatch = build(:delegation_intent_checkpoint, project: project, issue: foreign_issue)
      expect(mismatch).not_to be_valid
    end
  end

  describe "binding immutability" do
    it "ignores edits to the bound revision and question set instead of rewriting them" do
      checkpoint = create(:delegation_intent_checkpoint, project: project, issue: issue,
        design_revision: "abc123", question_set_digest: "digest1")

      checkpoint.update!(status: "settled")

      expect(checkpoint.reload.design_revision).to eq("abc123")
      expect(checkpoint.reload.question_set_digest).to eq("digest1")
    end
  end

  describe "#settlement_current?" do
    it "is true only while the settlement's bound revisions match" do
      checkpoint = create(:delegation_intent_checkpoint, project: project, issue: issue,
        design_revision: "abc123", acceptance_revision: "criteria:1")
      settlement = create(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint)

      expect(checkpoint.settlement_current?({ "design_revision" => "abc123", "acceptance_revision" => "criteria:1" })).to be(true)
      expect(checkpoint.settlement_current?({ "design_revision" => "def456", "acceptance_revision" => "criteria:1" })).to be(false)
      expect(checkpoint.settlement_current?({ "design_revision" => "abc123", "acceptance_revision" => "criteria:2" })).to be(false)
      expect(settlement).to be_settled
    end
  end
end
