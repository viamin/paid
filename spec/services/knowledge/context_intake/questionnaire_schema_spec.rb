# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::QuestionnaireSchema do
  describe ".ordered_questions" do
    it "bootstraps the default catalog into persisted question records" do
      expect { described_class.ordered_questions }.to change(ContextIntakeQuestion, :count).from(0)
      expect(described_class.ordered_questions).to all(include(:key, :text, :required, :round))
    end

    it "does not duplicate the shared catalog on repeated bootstraps" do
      described_class.ordered_questions

      expect { described_class.ordered_questions }.not_to change(ContextIntakeQuestion, :count)
    end

    it "recreates the shared catalog after it is deleted" do
      described_class.ordered_questions
      ContextIntakeQuestion.global_catalog.delete_all

      expect { described_class.ordered_questions }.to change(ContextIntakeQuestion, :count).from(0)
    end

    it "prefers project-specific questions when keys overlap with the shared catalog" do
      described_class.ordered_questions
      project = create(:project)
      create(:context_intake_question, project: project, key: "product_description", question_text: "Project version")

      question = described_class.find_question("product_description", project: project)
      expect(question.dig(:question, :text)).to eq("Project version")
    end
  end

  describe ".questions_for_section" do
    it "returns questions for a valid section" do
      questions = described_class.questions_for_section("product_purpose")
      expect(questions).not_to be_empty
      expect(questions).to all(include(:key, :text, :required, :round))
    end

    it "returns empty array for unknown section" do
      expect(described_class.questions_for_section("nonexistent")).to eq([])
    end
  end

  describe ".find_question" do
    it "returns section and question for a known key" do
      result = described_class.find_question("product_description")
      expect(result[:question][:key]).to eq("product_description")
      expect(result[:section][:key]).to eq("product_purpose")
    end

    it "returns nil for unknown key" do
      expect(described_class.find_question("nonexistent")).to be_nil
    end
  end

  describe ".total_questions" do
    it "returns a positive count" do
      expect(described_class.total_questions).to be > 0
    end
  end

  describe ".required_questions" do
    it "returns only required questions" do
      required = described_class.required_questions
      expect(required).to all(include(required: true))
      expect(required.size).to be > 0
    end
  end

  describe ".eligible_questions" do
    it "filters follow-up questions using answer-based conditions" do
      project = create(:project)
      response = create_matching_response(project)
      create_conditional_follow_up(project)

      eligible = described_class.eligible_questions(project: project, round: 2, responses: [ response ])
      expect(eligible.map { |question| question[:key] }).to include("enterprise_constraints")
    end
  end

  def create_matching_response(project)
    create(
      :context_intake_response,
      context_intake_session: create(:context_intake_session, project: project),
      question_key: "product_description",
      answer_text: "We support enterprise billing",
      section: "product_purpose"
    )
  end

  def create_conditional_follow_up(project)
    create(
      :context_intake_question,
      project: project,
      key: "enterprise_constraints",
      question_text: "What enterprise approval workflows matter here?",
      section_key: "operational_constraints",
      section_title: "Operational & Business Constraints",
      category: "operational_constraints",
      round: 2,
      section_order: 6,
      display_order: 0,
      is_follow_up: true,
      parent_question_key: "product_description",
      conditions: {
        "depends_on_question_key" => "product_description",
        "answer_includes_any" => [ "enterprise" ]
      }
    )
  end
end
