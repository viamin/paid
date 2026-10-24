# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SourceClosureDisposition do
  let(:issue) { create(:issue) }

  def assessment(criteria:, gaps: [])
    {
      "gaps" => gaps,
      "criteria" => criteria,
      "source_revision" => Issues::CloseoutEvidence.call(issue).digest,
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "assessed_at" => Time.current.iso8601
    }
  end

  it "permits closing only for current, fully satisfied criteria" do # @spec PARTIAL-CLOSEOUT-029
    result = described_class.call(issue: issue, assessment: assessment(criteria: [ { "criterion" => "live validation", "state" => "satisfied" } ]))

    expect(result.fetch("disposition")).to eq("close")
  end

  it "tracks unavailable or partial evidence" do # @spec PARTIAL-CLOSEOUT-029
    result = described_class.call(issue: issue, assessment: assessment(
      criteria: [ { "criterion" => "live validation", "state" => "unknown" } ],
      gaps: [ { "criterion" => "live validation", "kind" => "human" } ]
    ))

    expect(result.fetch("disposition")).to eq("track")
  end

  it "tracks a changed evidence revision" do # @spec PARTIAL-CLOSEOUT-029
    result = described_class.call(issue: issue, assessment: assessment(criteria: [ { "criterion" => "live validation", "state" => "satisfied" } ]).merge("source_revision" => "stale"))

    expect(result.fetch("disposition")).to eq("track")
  end
end
