# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::SaveResponse do
  let(:session) { create(:context_intake_session) }

  before do
    create(:context_intake_response,
      context_intake_session: session,
      question_key: "product_description",
      section: "product_purpose",
      is_follow_up: false)
  end

  describe ".call" do
    it "saves an answer to the response" do
      result = described_class.call(
        session: session,
        question_key: "product_description",
        answer_text: "We build robots."
      )

      expect(result.answer_text).to eq("We build robots.")
      expect(result.skipped).to be(false)
      expect(result.provenance).to eq("human")
    end

    it "marks a response as skipped" do
      result = described_class.call(
        session: session,
        question_key: "product_description",
        skipped: true
      )

      expect(result.skipped).to be(true)
      expect(result.answer_text).to be_nil
    end

    it "updates the session current_step" do
      described_class.call(
        session: session,
        question_key: "product_description",
        answer_text: "We build robots."
      )

      expect(session.reload.current_step).to eq(1)
    end

    it "raises when question_key is not found" do
      expect {
        described_class.call(
          session: session,
          question_key: "nonexistent",
          answer_text: "anything"
        )
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
