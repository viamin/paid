# frozen_string_literal: true

require "rails_helper"

# A post-unblinding correction is separately attributable evidence: it must
# never overwrite the sole judge's original blinded reference judgment.
# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseLabel do
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
      labels_frozen_at: Time.current)
  end
  let(:original_judgment) do
    {
      verdict: "completed", intent_band: "below_threshold", technical_band: "below_threshold",
      readiness: "not_ready", cited_evidence_reference: "sync-sketch-statement",
      reason: "Tentative exploration is not explicit direction."
    }
  end
  let(:corrected_judgment) do
    original_judgment.merge(
      intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", reason: "After comparing the frozen expectation, the cited evidence supports readiness."
    )
  end

  before do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", **original_judgment,
      recorded_by: owner, recorded_at: 1.minute.ago)
  end

  it "appends an attributed correction without changing the blinded judgment" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: corrected_judgment)

    expect(result).to be_success
    label = result.label
    expect(label).to have_attributes(**original_judgment)
    expect(label).to have_attributes(
      revised_verdict: "completed", revised_intent_band: "at_or_above_threshold",
      revised_technical_band: "at_or_above_threshold", revised_readiness: "ready",
      revised_cited_evidence_reference: "sync-sketch-statement",
      revised_reason: corrected_judgment[:reason], revised_by: owner
    )
    expect(label.revised_at).to be_present
  end

  it "refuses corrections before unblinding or by a different account member" do
    evaluation.update!(status: "labeling", labels_frozen_at: nil)
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: corrected_judgment)
    expect(result).not_to be_success
    expect(result.error).to include("frozen")

    evaluation.update!(status: "frozen", labels_frozen_at: Time.current)
    result = described_class.call(evaluation: evaluation, actor: member, case_id: "FC-CORPUS-01",
      judgment: corrected_judgment)
    expect(result).not_to be_success
    expect(result.error).to include("only the operator")
  end

  it "requires a valid cited case reference and refuses a second correction" do
    invalid = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: corrected_judgment.merge(cited_evidence_reference: "not-a-case-reference"))
    expect(invalid).not_to be_success

    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: corrected_judgment)).to be_success
    repeated = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: corrected_judgment)
    expect(repeated).not_to be_success
    expect(repeated.error).to include("immutable")
  end
end
