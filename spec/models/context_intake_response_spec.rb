# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContextIntakeResponse do
  subject(:response) { build(:context_intake_response) }

  describe "associations" do
    it { is_expected.to belong_to(:context_intake_session) }
    it { is_expected.to belong_to(:parent_response).class_name("ContextIntakeResponse").optional }
    it { is_expected.to have_many(:follow_up_responses).class_name("ContextIntakeResponse").dependent(:nullify) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:question_key) }
    it { is_expected.to validate_length_of(:question_key).is_at_most(200) }
    it { is_expected.to validate_presence_of(:question_text) }
    it { is_expected.to validate_presence_of(:section) }
    it { is_expected.to validate_length_of(:section).is_at_most(100) }
    it { is_expected.to validate_inclusion_of(:provenance).in_array(described_class::PROVENANCES) }
  end

  describe "scopes" do
    let(:session) { create(:context_intake_session) }

    describe ".answered" do
      it "returns responses with answers or skipped" do
        answered = create(:context_intake_response, :answered,
          context_intake_session: session, question_key: "q1")
        skipped = create(:context_intake_response, :skipped,
          context_intake_session: session, question_key: "q2")
        create(:context_intake_response,
          context_intake_session: session, question_key: "q3")

        expect(described_class.answered).to contain_exactly(answered, skipped)
      end
    end

    describe ".unanswered" do
      it "returns responses without answers and not skipped" do
        create(:context_intake_response, :answered,
          context_intake_session: session, question_key: "q1")
        unanswered = create(:context_intake_response,
          context_intake_session: session, question_key: "q2")

        expect(described_class.unanswered).to eq([ unanswered ])
      end
    end
  end

  describe "#answered?" do
    it "returns true when answer_text is present" do
      response = build(:context_intake_response, :answered)
      expect(response).to be_answered
    end

    it "returns true when skipped" do
      response = build(:context_intake_response, :skipped)
      expect(response).to be_answered
    end

    it "returns false when no answer and not skipped" do
      response = build(:context_intake_response)
      expect(response).not_to be_answered
    end
  end
end
