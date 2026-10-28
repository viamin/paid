# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-022
RSpec.describe Inbox::FacetConfidenceEscalation do
  let(:account) { create(:account) }
  let(:actor) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) { create(:issue, project:) }
  let(:notification) do
    create(:notification, :error, account:, subject: issue,
      source: described_class::SOURCE, blocking: true)
  end

  def record(evaluation, corpus_case)
    expected = corpus_case.fetch("expected")
    FacetConfidence::CloseoutEvaluation::RecordLabel.call(
      evaluation: evaluation,
      actor: actor,
      case_id: corpus_case.fetch("id"),
      judgment: {
        verdict: expected.fetch("status"),
        intent_band: expected.fetch("intent_band"),
        technical_band: expected.fetch("technical_band"),
        readiness: expected.fetch("readiness"),
        cited_evidence_reference: (expected["must_cite"] || corpus_case.fetch("evidence").map { |item| item.fetch("reference") }).first,
        reason: "Recorded after reviewing the cited evidence."
      }
    )
  end

  it "projects start, resume, continue, and freeze actions from the evaluation state" do
    expect(described_class.call(notification:, issue:)).to include(action_label: "Start evaluation")

    evaluation = FacetConfidence::CloseoutEvaluation::Start.call(project:, issue:, actor:).evaluation
    expect(described_class.call(notification:, issue:)).to include(action_label: "Resume evaluation", recorded: 0)

    record(evaluation, evaluation.corpus.cases.first)
    expect(described_class.call(notification:, issue:)).to include(action_label: "Continue judging", recorded: 1)

    evaluation.corpus.cases.drop(1).each { |corpus_case| record(evaluation, corpus_case) }
    expect(described_class.call(notification:, issue:)).to include(action_label: "Freeze judgments")
  end

  it "keeps untyped notifications on the generic Action Required path" do
    notification.update!(source: "other_action_required", metadata: {})

    expect(described_class.call(notification:, issue:)).to be_nil
  end
end
