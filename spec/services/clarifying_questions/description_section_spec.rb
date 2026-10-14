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

  describe ".update_issue_body" do
    it "rebuilds the section from a human edit that arrives before the write" do # @spec QUIET-MODE-010
      client = double
      initial_issue = Struct.new(:body).new("Original issue description")
      human_edited_issue = Struct.new(:body).new("Human edit before Paid writes")
      allow(client).to receive(:issue).and_return(initial_issue, human_edited_issue)
      allow(client).to receive(:update_issue)

      described_class.update_issue_body(client: client, repo: "paid/app", number: 42) do |body|
        described_class.replace_questions_section(body: body, questions: [ "Which events should be recorded?" ])
      end

      expect(client).to have_received(:update_issue).with(
        "paid/app",
        42,
        body: a_string_including("Human edit before Paid writes", described_class::QUESTIONS_OPEN_MARKER)
      )
    end
  end
end
