# frozen_string_literal: true

require "rails_helper"

# @spec ISSUE-ENHANCEMENT-020 @spec ISSUE-ENHANCEMENT-021
RSpec.describe ClarifyingQuestions::Normalize, :no_db do
  let(:structured_question) { "Which storage backend should the export use?" }
  let(:structured_details) do
    [
      {
        "question" => "Which storage backend should the export use?",
        "choices" => [
          { "label" => "SQLite", "text" => "local file, zero setup" },
          { "label" => "Postgres", "text" => "already used for app data" }
        ],
        "multiple" => false,
        "recommendation" => { "label" => "SQLite", "text" => "matches the existing export path" },
        "rationale" => "Both backends are vendored.",
        "examples" => [ "A nightly CSV dump written to a local path" ],
        "evidence" => [ "app/models/export.rb", "#1234" ]
      }
    ]
  end

  describe ".call" do
    context "with a legacy prose question" do
      it "keeps the full text as the label and infers nothing from the prose" do
        raw = "The export currently writes JSON. Should the export support CSV too?"

        questions = described_class.call(questions: [ raw ], details: [])

        expect(questions.size).to eq(1)
        expect(questions.first.raw).to eq(raw)
        expect(questions.first.question).to eq(raw)
        expect(questions.first.choices).to be_nil
        expect(questions.first.recommendation).to be_nil
        expect(questions.first.rationale).to be_nil
        expect(questions.first.examples).to be_nil
        expect(questions.first.evidence).to be_nil
        expect(questions.first.supporting_details?).to be(false)
      end
    end

    context "with a legacy marker choice question" do
      it "keeps the parsed choices and shows the text before the first marker as the label" do
        raw = "Which storage backend should the export use? " \
              "- ( ) SQLite) local file, zero setup " \
              "- ( ) Postgres) already used for app data"

        questions = described_class.call(questions: [ raw ], details: [])

        expect(questions.first.raw).to eq(raw)
        expect(questions.first.question).to eq("Which storage backend should the export use?")
        expect(questions.first.choices).to eq(
          type: :single,
          options: [
            { label: "SQLite", text: "local file, zero setup" },
            { label: "Postgres", text: "already used for app data" }
          ]
        )
        expect(questions.first.recommendation).to be_nil
      end
    end

    context "with a structured payload" do
      it "exposes the question, choices, recommendation, rationale, examples, and evidence" do
        question = described_class.call(questions: [ structured_question ], details: structured_details).first

        expect(question.raw).to eq(structured_question)
        expect(question.question).to eq(structured_question)
        expect(question.choices[:type]).to eq(:single)
        expect(question.choices[:options].map { |option| option[:label] }).to eq([ "SQLite", "Postgres" ])
        expect(question.recommendation).to eq(label: "SQLite", text: "matches the existing export path")
        expect(question.rationale).to eq("Both backends are vendored.")
        expect(question.examples).to eq([ "A nightly CSV dump written to a local path" ])
        expect(question.evidence).to eq([ "app/models/export.rb", "#1234" ])
        expect(question.supporting_details?).to be(true)
      end

      it "marks a multi-answer question as multi" do
        details = [
          {
            "question" => "Which browsers must the export UI support?",
            "choices" => [
              { "label" => "Chrome", "text" => "primary browser" },
              { "label" => "Firefox", "text" => "required by the support team" }
            ],
            "multiple" => true
          }
        ]

        questions = described_class.call(
          questions: [ "Which browsers must the export UI support?" ],
          details: details
        )

        expect(questions.first.choices[:type]).to eq(:multi)
      end

      it "ignores a payload entry that matches no question" do
        details = [
          {
            "question" => "Which other question was asked?",
            "rationale" => "not for this question"
          }
        ]

        questions = described_class.call(
          questions: [ "Which storage backend should the export use?" ],
          details: details
        )

        expect(questions.first.rationale).to be_nil
      end

      it "matches a payload entry against the question label of a legacy marker question" do
        raw = "Which storage backend should the export use? " \
              "- ( ) SQLite) local file, zero setup " \
              "- ( ) Postgres) already used for app data"

        questions = described_class.call(questions: [ raw ], details: structured_details)

        expect(questions.first.rationale).to eq("Both backends are vendored.")
        expect(questions.first.evidence).to eq([ "app/models/export.rb", "#1234" ])
      end
    end

    context "when the recommendation is not grounded" do
      it "omits a recommendation that carries no evidence reference" do
        details = [
          {
            "question" => "Which storage backend should the export use?",
            "choices" => [
              { "label" => "SQLite", "text" => "local file, zero setup" },
              { "label" => "Postgres", "text" => "already used for app data" }
            ],
            "recommendation" => { "label" => "SQLite", "text" => "a guess" }
          }
        ]

        questions = described_class.call(
          questions: [ "Which storage backend should the export use?" ],
          details: details
        )

        expect(questions.first.recommendation).to be_nil
        expect(questions.first.recommendation?).to be(false)
      end

      it "omits a recommendation that names an option the question does not offer" do
        details = [
          {
            "question" => "Which storage backend should the export use?",
            "choices" => [
              { "label" => "SQLite", "text" => "local file, zero setup" },
              { "label" => "Postgres", "text" => "already used for app data" }
            ],
            "recommendation" => { "label" => "Redis", "text" => "not on offer" },
            "evidence" => [ "app/models/export.rb" ]
          }
        ]

        questions = described_class.call(
          questions: [ "Which storage backend should the export use?" ],
          details: details
        )

        expect(questions.first.recommendation).to be_nil
      end

      it "keeps a grounded recommendation on a question without choices" do
        details = [
          {
            "question" => "Should the export run on a schedule?",
            "recommendation" => { "label" => "Nightly", "text" => "matches the existing cron job" },
            "evidence" => [ "app/jobs/export_job.rb" ]
          }
        ]

        questions = described_class.call(
          questions: [ "Should the export run on a schedule?" ],
          details: details
        )

        expect(questions.first.recommendation).to eq(
          label: "Nightly", text: "matches the existing cron job"
        )
      end
    end
  end
end
