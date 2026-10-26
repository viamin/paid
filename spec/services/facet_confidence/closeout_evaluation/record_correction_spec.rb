# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::RecordCorrection do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:corpus_path) { FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH }
  let(:evaluation) do
    FacetConfidenceEvaluation.create!(project: project, issue: issue, status: "frozen",
      corpus_path: corpus_path,
      corpus_digest: FacetConfidence::Corpus.new(path: corpus_path).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", source_revision: "intent-sha", created_by: owner,
      labels_frozen_at: Time.current, report: { "frozen" => true }, report_markdown: "original report")
  end
  let!(:label) do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed",
      intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded judgment.",
      recorded_by: owner, recorded_at: Time.current)
  end
  let(:correction) do
    {
      verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-sketch-statement",
      reason: "After unblinding, I corrected my reading of the cited statement."
    }
  end

  it "appends a correction without mutating the frozen label or report" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, correction: correction)

    expect(result).to be_success
    expect(result.label).to have_attributes(revised_verdict: "completed", revised_intent_band: "at_or_above_threshold",
      revised_technical_band: "at_or_above_threshold", revised_readiness: "ready",
      revised_cited_evidence_reference: "sync-sketch-statement", revised_reason: correction[:reason], revised_by: owner)
    expect(label.reload).to have_attributes(intent_band: "below_threshold", readiness: "not_ready")
    expect(evaluation.reload.report_markdown).to eq("original report")
  end

  it "requires the original judge, a frozen set, valid corpus evidence, and an internally consistent correction" do
    expect(described_class.call(evaluation: evaluation, actor: member, case_id: label.case_id, correction: correction).error)
      .to include("sole reference judge")
    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id,
      correction: correction.merge(cited_evidence_reference: "not-in-corpus")).error).to include("cited evidence")
    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id,
      correction: correction.merge(readiness: "not_ready")).error).to include("readiness")
  end
end
