# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::QuestionnaireSchema do
  describe ".sections" do
    it "returns a frozen array of sections" do
      expect(described_class.sections).to be_frozen
      expect(described_class.sections).to all(include(:key, :title, :questions))
    end

    it "has unique section keys" do
      keys = described_class.sections.map { |s| s[:key] }
      expect(keys).to eq(keys.uniq)
    end
  end

  describe ".questions_for_section" do
    it "returns questions for a valid section" do
      questions = described_class.questions_for_section("product_purpose")
      expect(questions).not_to be_empty
      expect(questions).to all(include(:key, :text, :required))
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
end
