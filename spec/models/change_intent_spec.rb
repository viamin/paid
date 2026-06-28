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

    it "rejects chat sessions from a different project" do
      other_project = create(:project)
      record = build(:change_intent, chat_session: create(:chat_session, project: other_project, account: other_project.account))

      expect(record).not_to be_valid
      expect(record.errors[:chat_session]).to include("must belong to the same project")
    end

    it "rejects issues from a different project" do
      other_project = create(:project)
      record = build(:change_intent, issue: create(:issue, project: other_project))

      expect(record).not_to be_valid
      expect(record.errors[:issue]).to include("must belong to the same project")
    end
  end

  describe "immutability" do
    it "prevents updating content fields after creation" do
      record = create(:change_intent)
      record.title = "New title"

      expect(record.save).to be false
      expect(record.errors[:title]).to include("is immutable after creation")
    end

    it "allows updating status" do
      record = create(:change_intent, :draft)
      record.status = "active"

      expect(record.save).to be true
    end
  end

  describe "#activate!" do
    it "transitions from draft to active status" do
      record = create(:change_intent, :draft)

      record.activate!

      expect(record.reload.status).to eq("active")
    end
  end
end
