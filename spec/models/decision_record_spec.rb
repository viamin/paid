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

    describe "project consistency" do
      it "rejects agent_run from a different project" do
        other_project = create(:project)
        other_run = create(:agent_run, :completed, project: other_project)
        record = build(:decision_record, agent_run: other_run)
        expect(record).not_to be_valid
        expect(record.errors[:agent_run]).to include("must belong to the same project")
      end

      it "rejects issue from a different project" do
        other_project = create(:project)
        other_issue = create(:issue, project: other_project)
        record = build(:decision_record, issue: other_issue)
        expect(record).not_to be_valid
        expect(record.errors[:issue]).to include("must belong to the same project")
      end

      it "rejects superseded_by from a different project" do
        other_project = create(:project)
        other_record = create(:decision_record, project: other_project)
        record = build(:decision_record, superseded_by: other_record)
        expect(record).not_to be_valid
        expect(record.errors[:superseded_by]).to include("must belong to the same project")
      end

      it "rejects superseded_by referencing itself" do
        record = create(:decision_record)
        record.superseded_by = record
        expect(record).not_to be_valid
        expect(record.errors[:superseded_by]).to include("cannot reference itself")
      end
    end
  end

  describe "immutability" do
    it "prevents updating content fields after creation" do
      record = create(:decision_record)
      record.title = "New title"
      expect(record.save).to be false
      expect(record.errors[:title]).to include("is immutable after creation")
    end

    it "prevents updating foreign key fields after creation" do
      record = create(:decision_record)
      other_project = create(:project)
      record.project_id = other_project.id
      expect(record.save).to be false
      expect(record.errors[:project_id]).to include("is immutable after creation")
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
    it "transitions from draft to active status" do
      record = create(:decision_record, :draft)
      record.activate!
      expect(record.reload.status).to eq("active")
    end

    it "raises when already active" do
      record = create(:decision_record, status: "active")
      expect { record.activate! }.to raise_error(DecisionRecord::InvalidTransitionError, /cannot activate from active/)
    end

    it "raises when superseded" do
      record = create(:decision_record, status: "superseded")
      expect { record.activate! }.to raise_error(DecisionRecord::InvalidTransitionError, /cannot activate from superseded/)
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

    it "raises when superseding with itself" do
      record = create(:decision_record)
      expect { record.supersede!(record) }.to raise_error(ArgumentError, "cannot supersede with itself")
    end

    it "raises when already superseded" do
      record = create(:decision_record, status: "superseded")
      other = create(:decision_record, project: record.project)
      expect { record.supersede!(other) }.to raise_error(DecisionRecord::InvalidTransitionError, /cannot supersede from superseded/)
    end

    it "raises when reverted" do
      record = create(:decision_record, status: "reverted")
      other = create(:decision_record, project: record.project)
      expect { record.supersede!(other) }.to raise_error(DecisionRecord::InvalidTransitionError, /cannot supersede from reverted/)
    end
  end

  describe "#revert!" do
    it "transitions to reverted status" do
      record = create(:decision_record)
      record.revert!
      expect(record.reload.status).to eq("reverted")
    end

    it "raises when already superseded" do
      record = create(:decision_record, status: "superseded")
      expect { record.revert! }.to raise_error(DecisionRecord::InvalidTransitionError, /cannot revert from superseded/)
    end

    it "raises when already reverted" do
      record = create(:decision_record, status: "reverted")
      expect { record.revert! }.to raise_error(DecisionRecord::InvalidTransitionError, /cannot revert from reverted/)
    end
  end
end
