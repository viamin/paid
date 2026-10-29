# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::SourceClosureEvidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  def create_audit_run(disposition:, criteria_satisfied:, source_revision: Issues::CloseoutEvidence.call(issue).digest)
    request = create(:issue_continuation_request, issue: issue, project: project,
      evidence: { "continuation_mode" => "acceptance_audit" })
    criteria = [ { "criterion" => "live validation", "state" => criteria_satisfied ? "satisfied" : "unknown" } ]
    gaps = criteria_satisfied ? [] : [ { "criterion" => "live validation", "kind" => "human", "next_step" => "Confirm live validation." } ]
    assessment = {
      "criteria" => criteria,
      "gaps" => gaps,
      "source_revision" => source_revision,
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "assessed_at" => Time.current.iso8601
    }
    create(:agent_run, :completed, project: project, issue: issue, goal: "analyze_issue",
      continuation_request: request,
      reconciliation: { "assessment" => assessment, "source_closure" => { "disposition" => disposition } })
  end

  # @spec PARTIAL-CLOSEOUT-038
  it "returns false when no acceptance-audit run has ever completed for the issue" do
    expect(described_class.current_close?(issue)).to be false
  end

  # @spec PARTIAL-CLOSEOUT-038
  it "returns false when a create_pr run exists but it is not an acceptance audit" do
    create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr")

    expect(described_class.current_close?(issue)).to be false
  end

  # @spec PARTIAL-CLOSEOUT-038
  it "returns true when the latest acceptance audit recorded a fresh close disposition" do
    create_audit_run(disposition: "close", criteria_satisfied: true)

    expect(described_class.current_close?(issue)).to be true
  end

  # @spec PARTIAL-CLOSEOUT-038
  it "returns false when the latest acceptance audit recorded a track disposition" do
    create_audit_run(disposition: "track", criteria_satisfied: false)

    expect(described_class.current_close?(issue)).to be false
  end

  # @spec PARTIAL-CLOSEOUT-038
  it "returns false when a recorded close disposition is stale against the current evidence revision" do
    create_audit_run(disposition: "close", criteria_satisfied: true, source_revision: "stale-digest")

    expect(described_class.current_close?(issue)).to be false
  end

  # @spec PARTIAL-CLOSEOUT-038
  it "does not call agent_harness to answer the question" do
    create_audit_run(disposition: "close", criteria_satisfied: true)
    expect(Llm::AnalyzePartialCloseout).not_to receive(:call)

    described_class.current_close?(issue)
  end
end
