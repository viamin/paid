# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::WizardState, :no_db do
  let(:response_class) { Struct.new(:answered?, keyword_init: true) }

  let(:responses) do
    {
      "product_description" => response_class.new(answered?: true),
      "business_model" => response_class.new(answered?: false),
      "primary_users" => response_class.new(answered?: false)
    }
  end

  describe "#current_question" do
    it "defaults to the next incomplete question when no explicit key is provided" do
      state = described_class.new(responses: responses)

      expect(state.current_question.fetch(:key)).to eq("business_model")
      expect(state.current_question_index).to eq(1)
      expect(state.current_question_number).to eq(2)
    end

    it "uses the explicitly requested question when it exists" do
      state = described_class.new(responses: responses, active_question_key: "primary_users")

      expect(state.current_question.fetch(:key)).to eq("primary_users")
      expect(state.current_question.fetch(:section_title)).to eq("Target Users & Markets")
    end
  end

  describe "step position helpers" do
    it "reports the schema-backed current step and total question count" do
      state = described_class.new(responses: responses, active_question_key: "primary_users")

      expect(state.current_question_number).to eq(3)
      expect(state.total_questions).to eq(
        Knowledge::ContextIntake::QuestionnaireSchema.total_questions
      )
    end
  end

  describe "#navigation_question_key" do
    it "moves backward and forward within the questionnaire bounds" do
      state = described_class.new(responses: responses)

      expect(state.navigation_question_key(current_question_key: "business_model", direction: "previous"))
        .to eq("product_description")
      expect(state.navigation_question_key(current_question_key: "product_description", direction: "previous"))
        .to eq("product_description")
      expect(state.navigation_question_key(current_question_key: "naming_conventions", direction: "next"))
        .to eq("naming_conventions")
    end
  end

  describe "boundary helpers" do
    it "does not expose a previous question for the first step" do
      state = described_class.new(responses: responses, active_question_key: "product_description")

      expect(state.first_question?).to be(true)
      expect(state.previous_question).to be_nil
    end

    it "marks the last step and omits a next question there" do
      state = described_class.new(responses: responses, active_question_key: "naming_conventions")

      expect(state.last_question?).to be(true)
      expect(state.next_question).to be_nil
    end
  end

  describe "#first_unanswered_required_question_key" do
    it "returns the first unanswered required question in questionnaire order" do
      state = described_class.new(
        responses: responses.merge("critical_journeys" => response_class.new(answered?: false)),
        active_question_key: "naming_conventions"
      )

      expect(state.first_unanswered_required_question_key).to eq("primary_users")
    end
  end
end
