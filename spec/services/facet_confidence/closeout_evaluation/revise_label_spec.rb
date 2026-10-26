# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseLabel do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:evaluation) do
    FacetConfidenceEvaluation.create!(project: project, issue: issue, status: "frozen",
      corpus_path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH,
      corpus_digest: FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", created_by: owner, labels_frozen_at: Time.current)
  end
  let!(:label) do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed",
      intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded reading.",
      recorded_by: owner, recorded_at: Time.current)
  end
  let(:judgment) do
    { verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-sketch-statement", reason: "Correction after unblinding." }
  end

  it "records a complete reasoned correction without mutating the original judgment" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, judgment: judgment)

    expect(result).to be_success
    expect(label.reload).to have_attributes(verdict: "completed", intent_band: "below_threshold", readiness: "not_ready")
    expect(label).to have_attributes(revised_verdict: "completed", revised_intent_band: "at_or_above_threshold",
      revised_technical_band: "at_or_above_threshold", revised_readiness: "ready",
      revised_cited_evidence_reference: "sync-sketch-statement", revised_reason: "Correction after unblinding.",
      revised_by: owner, revised_at: be_present)
  end

  it "rejects a correction from anyone other than the reference judge" do
    result = described_class.call(evaluation: evaluation, actor: member, case_id: label.case_id, judgment: judgment)

    expect(result).not_to be_success
    expect(result.error).to include("sole reference judge")
    expect(label.reload).not_to be_revised
  end

  it "requires a frozen labeled judgment, a complete consistent judgment, and a reason" do
    evaluation.update!(status: "labeling")
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, judgment: judgment)
    expect(result.error).to include("after the reference set is frozen")

    evaluation.update!(status: "frozen")
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id,
      judgment: judgment.merge(readiness: "not_ready", reason: ""))
    expect(result).not_to be_success
    expect(result.error).to match(/reason|readiness/i)
  end
end
