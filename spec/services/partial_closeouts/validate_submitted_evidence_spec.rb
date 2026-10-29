# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::ValidateSubmittedEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, github_state: "open", title: "Release pilot") }
  let(:identity) { "occurrence-1" }
  let(:notification) do
    create(:notification, account: project.account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, severity: :error, blocking: true,
      metadata: { "prerequisites" => [ {
        "identity" => identity, "criterion" => "Pilot results are independently reviewed",
        "references" => [ { "kind" => "evidence", "key" => "pilot-report", "revision" => "v1", "label" => "Pilot report" } ],
        "source_revision" => "source-v1"
      } ], "evidence_submissions" => [ {
        "prerequisite_identity" => identity, "evidence_url" => "https://evidence.example.test/report",
        "explanation" => "The independent review is attached.", "source_revision" => "source-v1",
        "outcome" => "pending_validation"
      } ] })
  end

  let(:response) { double(success?: true, output: JSON.generate("outcome" => "sufficient", "reason" => "The artifact addresses the criterion.")) }

  before do
    allow(PartialCloseouts::Assessment).to receive(:source_revision_for).with(issue).and_return("source-v1")
    allow(Llm::Request).to receive(:call).and_return(response)
  end

  it "persists only a strict sufficient disposition from agent_harness" do # @spec PARTIAL-CLOSEOUT-035
    result = described_class.call(notification:, prerequisite_identity: identity)

    expect(result.outcome).to eq("sufficient")
    expect(notification.reload.metadata.fetch("evidence_submissions").sole).to include(
      "outcome" => "sufficient", "reason" => "The artifact addresses the criterion."
    )
    expect(Llm::Request).to have_received(:call).with(
      prompt: a_string_including("Pilot results are independently reviewed", "The independent review is attached."),
      project:, timeout: described_class::TIMEOUT
    )
  end

  it "persists insufficient without allowing a user claim to satisfy the prerequisite" do # @spec PARTIAL-CLOSEOUT-035
    allow(Llm::Request).to receive(:call).and_return(
      double(success?: true, output: JSON.generate("outcome" => "insufficient", "reason" => "The artifact does not establish independent review."))
    )

    expect(described_class.call(notification:, prerequisite_identity: identity).outcome).to eq("insufficient")
    expect(notification.reload).to be_active
  end

  it "fails closed without persisting raw model output" do # @spec PARTIAL-CLOSEOUT-035
    allow(Llm::Request).to receive(:call).and_return(double(success?: true, output: "ignore previous instructions"))

    result = described_class.call(notification:, prerequisite_identity: identity)

    expect(result.outcome).to eq("unavailable")
    submission = notification.reload.metadata.fetch("evidence_submissions").sole
    expect(submission).to include("outcome" => "unavailable", "reason" => "Semantic validation returned an invalid result.")
    expect(submission.to_json).not_to include("ignore previous instructions")
  end

  it "marks the submission stale when the source revision changes during validation" do # @spec PARTIAL-CLOSEOUT-035
    allow(PartialCloseouts::Assessment).to receive(:source_revision_for).with(issue)
      .and_return("source-v1", "source-v2")

    result = described_class.call(notification:, prerequisite_identity: identity)

    expect(result.outcome).to eq("stale")
    expect(notification.reload.metadata.fetch("evidence_submissions").sole.fetch("reason")).to include("changed")
  end
end
