# frozen_string_literal: true

require "rails_helper"

# A post-unblinding correction is separately attributable evidence: it never
# overwrites or rescales the frozen blinded reference judgment.
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
      model_version: "claude-sonnet-4-6", source_revision: "intent-sha", labels_frozen_at: Time.current,
      created_by: owner)
  end
  let!(:label) do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed",
      intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded reading.",
      recorded_by: owner, recorded_at: Time.current)
  end
  let(:revision) do
    {
      verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-sketch-statement",
      reason: "After unblinding, I reconsider the prototype as sufficient technical evidence."
    }
  end

  it "appends a reasoned correction without replacing the frozen judgment or its measures" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, judgment: revision)

    expect(result).to be_success
    label.reload
    expect(label).to have_attributes(verdict: "completed", intent_band: "below_threshold", technical_band: "below_threshold",
      readiness: "not_ready", reason: "Original blinded reading.", revised_by: owner)
    expect(label.revision).to include("intent_band" => "at_or_above_threshold", "reason" => revision[:reason])
    expect(evaluation.reload.report.dig("measures", "readiness_divergences", "count")).to eq(0)
    expect(evaluation.report.dig("cases", 0, "revision", "reason")).to eq(revision[:reason])
  end

  it "refuses corrections before freeze, by another user, or without a reason" do
    evaluation.update!(status: "labeling", labels_frozen_at: nil)
    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, judgment: revision)).not_to be_success

    evaluation.update!(status: "frozen", labels_frozen_at: Time.current)
    expect(described_class.call(evaluation: evaluation, actor: member, case_id: label.case_id, judgment: revision)).not_to be_success
    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id,
      judgment: revision.merge(reason: " "))).not_to be_success
  end
end
