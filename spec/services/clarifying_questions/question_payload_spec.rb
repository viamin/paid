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

    it "omits an unsupported structured recommendation" do # @spec OPERATOR-INBOX-025
      payload = described_class.call(question: { "question" => "Which cache should exports use?", "recommendation" => "Redis" })

      expect(payload[:recommendation]).to be_nil
    end
  end
end
