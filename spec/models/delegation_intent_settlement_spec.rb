# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-002
RSpec.describe DelegationIntentSettlement do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }
  let(:checkpoint) { create(:delegation_intent_checkpoint, project: project, issue: issue) }

  describe "validations" do
    it "is valid from the factory" do
      expect(build(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint)).to be_valid
    end

    it "rejects an unknown disposition and malformed answers" do
      expect(build(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint, disposition: "finalized")).not_to be_valid
      expect(build(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint, answers: [ "bare string" ])).not_to be_valid
      expect(build(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint,
        answers: [ { "group_key" => "claim:x" } ])).not_to be_valid
    end

    it "rejects a settler from another account" do
      foreign_user = create(:user)

      expect(build(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint, settled_by: foreign_user)).not_to be_valid
    end
  end

  describe "append-only binding" do
    it "rejects updates at the database layer" do
      settlement = create(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint)

      expect { settlement.update!(disposition: "rejected") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "rejects deletes at the database layer" do
      settlement = create(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint)

      expect { settlement.destroy }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  describe "#answer_for" do
    it "returns the recorded answer for a group and nil otherwise" do
      settlement = create(:delegation_intent_settlement, delegation_intent_checkpoint: checkpoint,
        answers: [ { "group_key" => "claim:test", "answer" => "7 days." } ])

      expect(settlement.answer_for("claim:test")).to eq("7 days.")
      expect(settlement.answer_for("claim:other")).to be_nil
    end
  end
end
