# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-012
RSpec.describe ClarifyingQuestions::ChoiceAnswers, :no_db do
  let(:single_question) do
    "Which storage backend should the export use? " \
      "- ( ) SQLite) local file, zero setup " \
      "- ( ) Postgres) already used for app data"
  end
  let(:multi_question) do
    "Which browsers must the export UI support? " \
      "- [ ] Chrome) primary browser " \
      "- [ ] Firefox) required by the support team"
  end
  let(:free_text_question) { "What is the expected behavior?" }

  describe ".option_line" do
    it "serializes an option as its label followed by its text in parentheses" do
      expect(described_class.option_line(label: "Postgres", text: "already used for app data"))
        .to eq("Postgres (already used for app data)")
    end
  end

  describe ".parse" do
    it "splits a serialized answer into selections, others, and details lines" do
      result = described_class.parse(
        answer: "SQLite (local file, zero setup)\nOther: Redis if the team prefers\nDetails: needs ops review"
      )

      expect(result).to eq(
        selections: [ "SQLite (local file, zero setup)" ],
        others: [ "Redis if the team prefers" ],
        details: [ "needs ops review" ]
      )
    end

    it "returns empty collections for nil or blank answers" do
      expect(described_class.parse(answer: nil)).to eq(selections: [], others: [], details: [])
      expect(described_class.parse(answer: "  \n  ")).to eq(selections: [], others: [], details: [])
    end

    it "keeps a bare Other marker without text as a selection so validation rejects it" do
      expect(described_class.parse(answer: "Other:")).to eq(selections: [ "Other:" ], others: [], details: [])
    end
  end

  describe ".error_for" do
    it "accepts a single selection for a single-choice question" do
      expect(described_class.error_for(question: single_question, answer: "SQLite (local file, zero setup)")).to be_nil
    end

    it "accepts a selection with an appended details line" do
      answer = "Postgres (already used for app data)\nDetails: needs a connection string setting"

      expect(described_class.error_for(question: single_question, answer: answer)).to be_nil
    end

    it "accepts joined selections for a multi-choice question" do
      answer = "Chrome (primary browser)\nFirefox (required by the support team)"

      expect(described_class.error_for(question: multi_question, answer: answer)).to be_nil
    end

    it "accepts selections plus Other with its specification" do
      answer = "Chrome (primary browser)\nOther: Safari for the design team"

      expect(described_class.error_for(question: multi_question, answer: answer)).to be_nil
    end

    it "accepts Other alone with its specification" do
      expect(described_class.error_for(question: single_question, answer: "Other: Redis if ops prefers")).to be_nil
    end

    it "skips blank answers so the existing blank-answer validation handles them" do
      expect(described_class.error_for(question: single_question, answer: "  ")).to be_nil
    end

    it "never validates questions without parsed choices" do
      expect(described_class.error_for(question: free_text_question, answer: "Anything goes, even (forged) lines")).to be_nil
      expect(described_class.error_for(question: nil, answer: "Anything")).to be_nil
    end

    it "rejects a selection that is not one of the offered options" do
      error = described_class.error_for(question: single_question, answer: "Redis (not offered)")

      expect(error).to include("isn't one of the offered options")
    end

    it "names the answer position when given" do
      error = described_class.error_for(question: single_question, answer: "Redis (not offered)", position: 2)

      expect(error).to start_with("Answer 2")
    end

    it "rejects multiple selections for a single-choice question" do
      answer = "SQLite (local file, zero setup)\nPostgres (already used for app data)"

      expect(described_class.error_for(question: single_question, answer: answer))
        .to include("select exactly one option")
    end

    it "rejects pairing a selection with Other on a single-choice question" do
      answer = "SQLite (local file, zero setup)\nOther: actually Redis"

      expect(described_class.error_for(question: single_question, answer: answer))
        .to include("select exactly one option")
    end

    it "rejects Other without a written specification" do
      expect(described_class.error_for(question: single_question, answer: "Other:   "))
        .to include("describe your answer")
    end

    it "rejects an answer with no selection or Other" do
      expect(described_class.error_for(question: single_question, answer: "Details: only details"))
        .to include("select at least one")
    end

    it "rejects more than one Other line" do
      answer = "Other: first\nOther: second"

      expect(described_class.error_for(question: multi_question, answer: answer))
        .to include("only one Other response")
    end

    it "rejects combining an Other response with a separate details line" do
      answer = "Chrome (primary browser)\nOther: Safari\nDetails: confirm with design"

      expect(described_class.error_for(question: multi_question, answer: answer))
        .to include("Details cannot accompany Other")
    end
  end
end
