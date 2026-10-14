# frozen_string_literal: true

require "rails_helper"

# @spec QUIET-MODE-011
RSpec.describe ClarifyingQuestions::DescriptionSection, :no_db do
  describe ".replace_questions_section" do
    it "replaces the prior preamble with the current enhancement context" do
      initial_body = described_class.replace_questions_section(
        body: "Original issue description",
        questions: [ "Which events should be recorded?" ],
        preamble: "Prior enhancement context."
      )

      replaced_body = described_class.replace_questions_section(
        body: initial_body,
        questions: [ "Which compliance events are required?" ],
        preamble: "Current enhancement context."
      )

      expect(replaced_body).to include("Current enhancement context.")
      expect(replaced_body).not_to include("Prior enhancement context.")
      expect(replaced_body.scan(described_class::QUESTIONS_OPEN_MARKER)).to contain_exactly(
        described_class::QUESTIONS_OPEN_MARKER
      )
    end
  end
end
