# frozen_string_literal: true

require "rails_helper"

# A post-unblinding correction is separate evidence: it never overwrites the
# blinded reference judgment that the frozen report measured.
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
      model_version: "claude-sonnet-4-6", source_revision: "intent-sha", created_by: owner,
      labels_frozen_at: Time.current)
  end
  let!(:label) do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed",
      intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded judgment.",
      recorded_by: owner, recorded_at: Time.current)
  end
  let(:revision) do
    {
      verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-spike-note",
      reason: "After unblinding, the explicit commitment changes my policy assessment."
    }
  end

  it "preserves the blinded judgment and records a reasoned post-unblinding revision" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, revision: revision)

    expect(result).to be_success
    label.reload
    expect(label).to have_attributes(verdict: "completed", intent_band: "below_threshold",
      technical_band: "below_threshold", readiness: "not_ready", reason: "Original blinded judgment.")
    expect(label).to have_attributes(**revision.transform_keys { |key| "revised_#{key}".to_sym }, revised_by: owner)
    expect(label.revised_at).to be_present
    expect(evaluation.reload.report.fetch("cases").first.fetch("revision")).to include("reason" => revision[:reason])
    expect(evaluation.report_markdown).to include("Post-unblinding corrections", revision[:reason])
  end

  it "requires the original judge, a frozen set, and an independent revision reason" do
    result = described_class.call(evaluation: evaluation, actor: member, case_id: label.case_id, revision: revision)
    expect(result).not_to be_success
    expect(result.error).to include("sole reference judge")

    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id,
      revision: revision.merge(reason: " "))
    expect(result).not_to be_success
    expect(result.error).to include("reason")
  end

  it "rejects a revision citation outside the original case evidence" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id,
      revision: revision.merge(cited_evidence_reference: "not-case-evidence"))

    expect(result).not_to be_success
    expect(result.error).to include("cited evidence")
  end
end
