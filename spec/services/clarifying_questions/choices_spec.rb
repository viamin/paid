# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::Choices, :no_db do
  describe ".call" do
    context "with strict single-choice markers" do
      it "extracts label/text options from a folded question" do
        question = "Which storage backend should the export use? " \
                   "- ( ) SQLite) local file, zero setup " \
                   "- ( ) Postgres) already used for app data " \
                   "- ( ) Flat JSON) easiest to diff"

        expect(described_class.call(question: question)).to eq(
          type: :single,
          options: [
            { label: "SQLite", text: "local file, zero setup" },
            { label: "Postgres", text: "already used for app data" },
            { label: "Flat JSON", text: "easiest to diff" }
          ]
        )
      end

      it "parses markers that survived Parse's line folding" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. Which storage backend should the export use?
             - ( ) SQLite) local file, zero setup
             - ( ) Postgres) already used for app data
          2. Should the export run on a schedule?

          ## Current context
          - The issue mentions a new feature
        COMMENT

        questions = ClarifyingQuestions::Parse.call(comment_body: body)

        expect(questions.size).to eq(2)
        expect(described_class.call(question: questions.first)).to eq(
          type: :single,
          options: [
            { label: "SQLite", text: "local file, zero setup" },
            { label: "Postgres", text: "already used for app data" }
          ]
        )
        expect(described_class.call(question: questions.second)).to be_nil
      end

      it "keeps the folded question string byte-identical for the tamper guard" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. Which storage backend should the export use?
             - ( ) SQLite) local file, zero setup
             - ( ) Postgres) already used for app data
          2. Should the export run on a schedule?
        COMMENT

        questions = ClarifyingQuestions::Parse.call(comment_body: body)

        # Choices must parse the markers that survived Parse's line folding
        # without Parse (or anything else) rewriting the question string.
        expect(questions.first).to eq(
          "Which storage backend should the export use? " \
          "- ( ) SQLite) local file, zero setup " \
          "- ( ) Postgres) already used for app data"
        )
      end

      it "allows descriptions containing parentheses" do
        question = "Which format? " \
                   "- ( ) CSV) easiest to diff (see the import tooling) " \
                   "- ( ) JSON) nests well"

        expect(described_class.call(question: question)).to eq(
          type: :single,
          options: [
            { label: "CSV", text: "easiest to diff (see the import tooling)" },
            { label: "JSON", text: "nests well" }
          ]
        )
      end
    end

    context "with strict multi-choice markers" do
      it "extracts checkbox-family options as multi" do
        question = "Which browsers must the export UI support? " \
                   "- [ ] Chrome) primary browser for most users " \
                   "- [ ] Firefox) required by the support team"

        expect(described_class.call(question: question)).to eq(
          type: :multi,
          options: [
            { label: "Chrome", text: "primary browser for most users" },
            { label: "Firefox", text: "required by the support team" }
          ]
        )
      end

      it "accepts the checked-box - [x] spelling as multi" do
        question = "Which browsers must the export UI support? " \
                   "- [x] Chrome) primary browser " \
                   "- [x] Firefox) required by the support team"

        expect(described_class.call(question: question)).to eq(
          type: :multi,
          options: [
            { label: "Chrome", text: "primary browser" },
            { label: "Firefox", text: "required by the support team" }
          ]
        )
      end
    end

    context "without strict markers" do
      it "returns nil for options named in prose" do
        question = "Should we use Option A: store exports in SQLite, or Option B: store exports in Postgres?"

        expect(described_class.call(question: question)).to be_nil
      end

      it "returns nil for a plain prose question" do
        question = "What is the expected behavior when the export file already exists?"

        expect(described_class.call(question: question)).to be_nil
      end

      it "returns nil for context bullets folded into the question" do
        question = "What format should the export use? The issue mentions CSV. " \
                   "- The import code lives in app/services/exports " \
                   "- The roadmap defers XML support"

        expect(described_class.call(question: question)).to be_nil
      end

      it "returns nil for nil or empty questions" do
        expect(described_class.call(question: nil)).to be_nil
        expect(described_class.call(question: "")).to be_nil
      end
    end

    context "with malformed or partial markers" do
      it "returns nil when only one option is marked" do
        question = "Which storage backend should the export use? - ( ) SQLite) local file, zero setup"

        expect(described_class.call(question: question)).to be_nil
      end

      it "returns nil when an option has no label/description separator" do
        question = "Which backend? - ( ) SQLite - ( ) Postgres) already used for app data"

        expect(described_class.call(question: question)).to be_nil
      end

      it "returns nil when an option has no description" do
        question = "Which backend? - ( ) SQLite) - ( ) Postgres) already used for app data"

        expect(described_class.call(question: question)).to be_nil
      end

      it "returns nil when a trailing marker has no content" do
        question = "Which backend? - ( ) SQLite) local file, zero setup - ( )"

        expect(described_class.call(question: question)).to be_nil
      end

      it "returns nil when marker families are mixed" do
        question = "Which settings apply? - ( ) SQLite) local file - [ ] Postgres) remote host"

        expect(described_class.call(question: question)).to be_nil
      end

      it "returns nil when the marker spelling is not the strict one" do
        question = "Which backend? -( ) SQLite) local - ( ) Postgres) remote"

        expect(described_class.call(question: question)).to be_nil
      end
    end
  end
end
