# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::QuestionPayload do
  describe ".call" do
    it "keeps a legacy question intact without inferring a recommendation" do # @spec OPERATOR-INBOX-025
      payload = described_class.call(question: "We found Redis. Should this use Redis or Postgres?")

      expect(payload).to include(
        question: "We found Redis. Should this use Redis or Postgres?",
        recommendation: nil,
        rationale: nil,
        examples: [],
        evidence_references: [],
        structured: false
      )
    end

    it "shows a structured recommendation only with evidence references" do # @spec OPERATOR-INBOX-025
      payload = described_class.call(question: {
        "question" => "Which cache should exports use?",
        "choices" => [ { "label" => "Redis", "detail" => "Shared cache" }, { "label" => "Postgres", "detail" => "Persistent rows" } ],
        "recommendation" => "Redis",
        "rationale" => "Existing workers already use it.",
        "examples" => [ "Nightly exports" ],
        "evidence_references" => [ "app/jobs/export_job.rb:12" ]
      })

      expect(payload).to include(question: "Which cache should exports use?", recommendation: "Redis", structured: true)
      expect(payload[:choices][:options]).to contain_exactly({ label: "Redis", text: "Shared cache" }, { label: "Postgres", text: "Persistent rows" })
    end

    it "preserves multi-answer choice semantics from a structured payload" do # @spec ISSUE-ENHANCEMENT-018
      payload = described_class.call(question: {
        "question" => "Which browsers should the export support?",
        "choice_type" => "multi",
        "choices" => [ { "label" => "Chrome", "detail" => "Primary browser" }, { "label" => "Firefox", "detail" => "Support team requirement" } ]
      })

      expect(payload[:choices][:type]).to eq(:multi)
    end

    it "omits an unsupported structured recommendation" do # @spec OPERATOR-INBOX-025
      payload = described_class.call(question: { "question" => "Which cache should exports use?", "recommendation" => "Redis" })

      expect(payload[:recommendation]).to be_nil
    end
  end

  describe ".reconcile" do
    let(:stored_question) do
      {
        "question" => "Which scope should ship first?",
        "choices" => [
          { "label" => "API", "detail" => "Ship the API first" },
          { "label" => "UI", "detail" => "Ship the UI first" }
        ]
      }
    end
    let(:posted) { "Which scope should ship first? - ( ) API) Ship the API first - ( ) UI) Ship the UI first" }

    it "keeps the stored structured payload when the posted markers match its choices" do # @spec OPERATOR-INBOX-025
      expect(described_class.reconcile(comment_questions: [ posted ], stored_questions: [ stored_question ]))
        .to eq([ stored_question ])
    end

    it "falls back to the posted question when a choice edit leaves the label unchanged" do # @spec QUIET-MODE-011
      edited = "Which scope should ship first? - ( ) API) Ship the API first - ( ) CLI) Ship the CLI first"

      expect(described_class.reconcile(comment_questions: [ edited ], stored_questions: [ stored_question ]))
        .to eq([ edited ])
    end

    it "falls back to the posted question when every choice marker was removed" do # @spec QUIET-MODE-011
      edited = "Which scope should ship first?"

      expect(described_class.reconcile(comment_questions: [ edited ], stored_questions: [ stored_question ]))
        .to eq([ edited ])
    end

    it "falls back to the posted question when markers were added to a stored freeform question" do # @spec QUIET-MODE-011
      stored = { "question" => "Which scope should ship first?" }

      expect(described_class.reconcile(comment_questions: [ posted ], stored_questions: [ stored ]))
        .to eq([ posted ])
    end

    it "keeps the stored payload when neither side carries choices" do # @spec OPERATOR-INBOX-025
      stored = { "question" => "Which scope should ship first?" }

      expect(described_class.reconcile(comment_questions: [ "Which scope should ship first?" ], stored_questions: [ stored ]))
        .to eq([ stored ])
    end
  end
end
