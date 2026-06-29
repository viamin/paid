# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeIntent do
  subject(:change_intent) { build(:change_intent) }

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:chat_session).optional }
    it { is_expected.to belong_to(:issue).optional }
    it { is_expected.to belong_to(:superseded_by).class_name("ChangeIntent").optional }
    it { is_expected.to have_many(:supersedes).class_name("ChangeIntent") }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_length_of(:title).is_at_most(500) }
    it { is_expected.to validate_presence_of(:intent) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "rejects a chat session from a different project" do
      other_project = create(:project)
      other_session = create(:chat_session, :with_project, account: other_project.account, project: other_project)
      record = build(:change_intent, chat_session: other_session)

      expect(record).not_to be_valid
      expect(record.errors[:chat_session]).to include("must belong to the same project")
    end

    it "accepts a referenced chat session for the same project" do
      project = create(:project)
      session = create(:chat_session, account: project.account, project: nil)
      create(:chat_session_project, chat_session: session, project: project)
      record = build(:change_intent, project: project, chat_session: session, issue: create(:issue, project: project))

      expect(record).to be_valid
    end

    it "rejects an issue from a different project" do
      other_issue = create(:issue)
      record = build(:change_intent, issue: other_issue)

      expect(record).not_to be_valid
      expect(record.errors[:issue]).to include("must belong to the same project")
    end

    it "rejects superseded_by from a different project" do
      other_record = create(:change_intent)
      record = build(:change_intent, superseded_by: other_record)

      expect(record).not_to be_valid
      expect(record.errors[:superseded_by]).to include("must belong to the same project")
    end

    it "rejects superseded_by referencing itself" do
      record = create(:change_intent)
      record.superseded_by = record

      expect(record).not_to be_valid
      expect(record.errors[:superseded_by]).to include("cannot reference itself")
    end
  end

  describe "immutability" do
    it "prevents updating content fields after creation" do
      record = create(:change_intent)
      record.title = "Updated title"

      expect(record.save).to be false
      expect(record.errors[:title]).to include("is immutable after creation")
    end

    it "allows updating status" do
      record = create(:change_intent, :draft)
      record.status = "active"

      expect(record.save).to be true
    end

    it "allows updating superseded_by" do
      record = create(:change_intent)
      replacement = create(:change_intent, project: record.project)
      record.superseded_by = replacement

      expect(record.save).to be true
    end
  end

  describe "scopes" do
    it "returns only active records from .active" do
      active = create(:change_intent, status: "active")
      create(:change_intent, :draft)

      expect(described_class.active).to eq([ active ])
    end

    it "returns only draft records from .draft" do
      create(:change_intent, status: "active")
      draft = create(:change_intent, :draft)

      expect(described_class.draft).to eq([ draft ])
    end
  end

  describe "#activate!" do
    it "transitions from draft to active" do
      record = create(:change_intent, :draft)

      record.activate!

      expect(record.reload.status).to eq("active")
    end

    it "raises when not in draft" do
      record = create(:change_intent, status: "active")

      expect { record.activate! }.to raise_error(ChangeIntent::InvalidTransitionError, /cannot activate from active/)
    end
  end

  describe "#supersede!" do
    it "marks the record as superseded by the given record" do
      original = create(:change_intent)
      replacement = create(:change_intent, project: original.project)

      original.supersede!(replacement)

      expect(original.reload.status).to eq("superseded")
      expect(original.superseded_by).to eq(replacement)
    end

    it "raises when superseding with itself" do
      record = create(:change_intent)

      expect { record.supersede!(record) }.to raise_error(ArgumentError, "cannot supersede with itself")
    end

    it "raises when already superseded" do
      record = create(:change_intent, status: "superseded")
      replacement = create(:change_intent, project: record.project)

      expect { record.supersede!(replacement) }.to raise_error(ChangeIntent::InvalidTransitionError, /cannot supersede from superseded/)
    end
  end
end
