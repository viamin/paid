# frozen_string_literal: true

require "rails_helper"

# @spec ISSUE-ENHANCEMENT-020
RSpec.describe ClarifyingQuestions::StructuredPayload, :no_db do
  let(:well_formed_entry) do
    {
      "question" => "Which storage backend should the export use?",
      "choices" => [
        { "label" => "SQLite", "text" => "local file, zero setup" },
        { "label" => "Postgres", "text" => "already used for app data" }
      ],
      "multiple" => true,
      "recommendation" => { "label" => "SQLite", "text" => "matches the existing export path" },
      "rationale" => "Both backends are vendored.",
      "examples" => [ "A nightly CSV dump written to a local path" ],
      "evidence" => [ "app/models/export.rb", "#1234" ]
    }
  end

  describe ".call" do
    it "returns an empty array when the payload is missing or not a list" do
      expect(described_class.call(payload: nil)).to eq([])
      expect(described_class.call(payload: "not a list")).to eq([])
      expect(described_class.call(payload: { "question" => "Which backend?" })).to eq([])
    end

    it "keeps the six payload fields of a well-formed entry" do
      expect(described_class.call(payload: [ well_formed_entry ])).to eq([ well_formed_entry ])
    end

    it "reads entries whose keys were symbolized by the JSON parser" do
      symbolized = well_formed_entry.deep_symbolize_keys

      expect(described_class.call(payload: [ symbolized ])).to eq([ well_formed_entry ])
    end

    it "drops entries without a usable question" do
      payload = [
        { "question" => "  " },
        { "question" => nil },
        "not an object",
        { "question" => "Which backend?" }
      ]

      expect(described_class.call(payload: payload)).to eq([ { "question" => "Which backend?" } ])
    end

    it "drops choice entries without a label and discards a choice list with fewer than two options" do
      payload = [
        {
          "question" => "Which backend?",
          "choices" => [ { "label" => "  " }, { "label" => "SQLite", "text" => "local file" } ]
        },
        {
          "question" => "Which format?",
          "choices" => [ { "label" => "CSV", "text" => "easy to diff" } ]
        }
      ]

      expect(described_class.call(payload: payload)).to eq(
        [ { "question" => "Which backend?" }, { "question" => "Which format?" } ]
      )
    end

    it "drops a recommendation without a label" do
      payload = [
        { "question" => "Which backend?", "recommendation" => { "label" => " " } },
        { "question" => "Which format?", "recommendation" => "SQLite" }
      ]

      expect(described_class.call(payload: payload)).to eq(
        [ { "question" => "Which backend?" }, { "question" => "Which format?" } ]
      )
    end

    it "drops blank rationale, examples, and evidence" do
      payload = [
        {
          "question" => "Which backend?",
          "rationale" => "   ",
          "examples" => [ "  ", "A nightly dump" ],
          "evidence" => []
        }
      ]

      expect(described_class.call(payload: payload)).to eq(
        [ { "question" => "Which backend?", "examples" => [ "A nightly dump" ] } ]
      )
    end

    it "only marks a question as multi-answer when the flag says so" do
      payload = [
        { "question" => "Which backend?", "multiple" => "true" },
        { "question" => "Which format?", "multiple" => nil }
      ]

      expect(described_class.call(payload: payload)).to eq(
        [ { "question" => "Which backend?", "multiple" => true }, { "question" => "Which format?" } ]
      )
    end
  end
end
