# frozen_string_literal: true

require "rails_helper"

RSpec.describe DecisionRecord do
  subject(:decision_record) { build(:decision_record) }

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:agent_run).optional }
    it { is_expected.to belong_to(:issue).optional }
    it { is_expected.to belong_to(:superseded_by).class_name("DecisionRecord").optional }
    it { is_expected.to have_many(:decision_record_links).dependent(:destroy) }
    it { is_expected.to have_many(:supersedes).class_name("DecisionRecord") }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_length_of(:title).is_at_most(500) }
    it { is_expected.to validate_presence_of(:summary) }
    it { is_expected.to validate_presence_of(:decision) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_length_of(:commit_sha_start).is_at_most(40) }
    it { is_expected.to validate_length_of(:commit_sha_end).is_at_most(40) }
  end

  describe "immutability" do
    it "prevents updating content fields after creation" do
      record = create(:decision_record)
      record.title = "New title"
      expect(record.save).to be false
      expect(record.errors[:title]).to include("is immutable after creation")
    end

    it "allows updating status" do
      record = create(:decision_record)
      record.status = "superseded"
      expect(record.save).to be true
    end

    it "allows updating superseded_by" do
      record = create(:decision_record)
      new_record = create(:decision_record, project: record.project)
      record.superseded_by = new_record
      expect(record.save).to be true
    end
  end

  describe "scopes" do
    describe ".active" do
      it "returns only active records" do
        active = create(:decision_record, status: "active")
        create(:decision_record, :draft)
        expect(described_class.active).to eq([ active ])
      end
    end

    describe ".draft" do
      it "returns only draft records" do
        create(:decision_record, status: "active")
        draft = create(:decision_record, :draft)
        expect(described_class.draft).to eq([ draft ])
      end
    end
  end

  describe "#activate!" do
    it "transitions to active status" do
      record = create(:decision_record, :draft)
      record.activate!
      expect(record.reload.status).to eq("active")
    end
  end

  describe "#supersede!" do
    it "marks the record as superseded by the given record" do
      original = create(:decision_record)
      new_record = create(:decision_record, project: original.project)
      original.supersede!(new_record)
      expect(original.reload.status).to eq("superseded")
      expect(original.superseded_by).to eq(new_record)
    end
  end

  describe "#revert!" do
    it "transitions to reverted status" do
      record = create(:decision_record)
      record.revert!
      expect(record.reload.status).to eq("reverted")
    end
  end
end
