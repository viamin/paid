# frozen_string_literal: true

require "rails_helper"

# Post-unblinding corrections append evidence; they never replace the frozen
# blinded reference label or its report. @spec FACET-CONFIDENCE-022
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
      model_version: "claude-sonnet-4-6", source_revision: "intent-sha", created_by: owner,
      labels_frozen_at: Time.current)
  end
  let!(:label) do
    FacetConfidenceEvaluationLabel.create!(facet_confidence_evaluation: evaluation,
      case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed", intent_band: "below_threshold",
      technical_band: "below_threshold", readiness: "not_ready", cited_evidence_reference: "sync-sketch-statement",
      reason: "Original blinded reason.", recorded_by: owner, recorded_at: Time.current)
  end
  let(:judgment) do
    { verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "below_threshold",
      readiness: "not_ready", cited_evidence_reference: "sync-sketch-statement", reason: "Corrected after unblinding." }
  end

  it "appends the corrected judgment without changing the original blinded label" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, judgment: judgment)

    expect(result).to be_success
    expect(label.reload).to have_attributes(intent_band: "below_threshold", reason: "Original blinded reason.")
    expect(result.revision).to have_attributes(**judgment, recorded_by: owner)
  end

  it "requires a correction reason and the sole reference judge" do
    blank_reason = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, judgment: judgment.merge(reason: ""))
    other_judge = described_class.call(evaluation: evaluation, actor: member, case_id: label.case_id, judgment: judgment)

    expect(blank_reason).not_to be_success
    expect(other_judge).not_to be_success
    expect(evaluation.label_revisions).to be_empty
  end
end
