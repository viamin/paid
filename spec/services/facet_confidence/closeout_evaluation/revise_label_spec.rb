# frozen_string_literal: true

require "rails_helper"

# A post-unblinding correction is appended to, never substituted for, the
# frozen blinded judgment that supplies the evaluation evidence.
# @spec FACET-CONFIDENCE-022
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseLabel do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:evaluation) do
    FacetConfidenceEvaluation.create!(project:, issue:, status: "frozen",
      corpus_path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH,
      corpus_digest: FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", created_by: owner, labels_frozen_at: Time.current)
  end
  let!(:label) do
    FacetConfidenceEvaluationLabel.create!(facet_confidence_evaluation: evaluation,
      case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed",
      intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded judgment.",
      recorded_by: owner, recorded_at: Time.current)
  end

  def call(actor: owner, **attributes)
    described_class.call(evaluation:, actor:, case_id: "FC-CORPUS-01", **attributes)
  end

  it "appends a reasoned correction while preserving the frozen judgment" do
    result = call(revision: {
      verdict: "unknown", intent_band: "unknown", technical_band: "at_or_above_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-spike-note", reason: "After unblinding, the evidence supports unknown intent."
    })

    expect(result).to be_success
    expect(label.reload).to have_attributes(verdict: "completed", intent_band: "below_threshold",
      revised_verdict: "unknown", revised_intent_band: "unknown", revised_technical_band: "at_or_above_threshold",
      revised_readiness: "not_ready", revised_cited_evidence_reference: "sync-spike-note", revised_by: owner)
    expect(label.revised_reason).to eq("After unblinding, the evidence supports unknown intent.")
    expect(label.revised_at).to be_present
  end

  it "requires the authenticated sole judge, frozen label, coherent bands, and a reason" do
    expect(call(actor: member, revision: {})).not_to be_success
    expect(call(revision: {})).not_to be_success
    expect(call(revision: { verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "not_ready", cited_evidence_reference: "sync-sketch-statement", reason: "Contradictory readiness." })).not_to be_success
  end
end
