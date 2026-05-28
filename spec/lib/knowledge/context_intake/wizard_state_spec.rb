# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::WizardState, :no_db do
  let(:response_class) do
    Struct.new(
      :question_key,
      :question_text,
      :section,
      :answer_data,
      :sequence,
      :created_at,
      :answered?,
      keyword_init: true
    )
  end

  let(:responses) do
    {
      "product_description" => build_response("product_description", "Product Purpose", 0, true),
      "business_model" => build_response("business_model", "Product Purpose", 1, false),
      "primary_users" => build_response("primary_users", "Target Users & Markets", 0, false, section: "target_users", section_order: 1)
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
      expect(state.total_questions).to eq(responses.size)
    end
  end

  describe "#navigation_question_key" do
    it "moves backward and forward within the questionnaire bounds" do
      state = described_class.new(responses: responses)

      expect(state.navigation_question_key(current_question_key: "business_model", direction: "previous"))
        .to eq("product_description")
      expect(state.navigation_question_key(current_question_key: "product_description", direction: "previous"))
        .to eq("product_description")
      expect(state.navigation_question_key(current_question_key: "primary_users", direction: "next"))
        .to eq("primary_users")
    end
  end

  describe "boundary helpers" do
    it "does not expose a previous question for the first step" do
      state = described_class.new(responses: responses, active_question_key: "product_description")

      expect(state.first_question?).to be(true)
      expect(state.previous_question).to be_nil
    end

    it "marks the last step and omits a next question there" do
      state = described_class.new(responses: responses, active_question_key: "primary_users")

      expect(state.last_question?).to be(true)
      expect(state.next_question).to be_nil
    end
  end

  describe "#first_unanswered_required_question_key" do
    it "returns the first unanswered required question in questionnaire order" do
      state = described_class.new(
        responses: responses.merge(
          "critical_journeys" => build_response("critical_journeys", "Core Workflows", 0, false, section: "core_workflows", section_order: 2)
        ),
        active_question_key: "primary_users"
      )

      expect(state.first_unanswered_required_question_key).to eq("primary_users")
    end
  end

  def build_response(key, section_title, display_order, answered, section: "product_purpose", section_order: 0)
    response_class.new(
      question_key: key,
      question_text: key.humanize,
      section: section,
      answer_data: {
        "question" => {
          "required" => key != "business_model",
          "round" => 1,
          "section_order" => section_order,
          "display_order" => display_order,
          "section_title" => section_title,
          "is_follow_up" => false,
          "conditions" => {},
          "validation_rules" => {},
          "provenance" => "human",
          "status" => "approved",
          "metadata" => {}
        }
      },
      sequence: display_order,
      created_at: Time.current,
      answered?: answered
    )
  end
end
