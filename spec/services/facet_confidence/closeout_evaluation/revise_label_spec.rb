# frozen_string_literal: true

require "rails_helper"

# Post-unblinding corrections preserve the blinded baseline and its measures.
# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseLabel do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:evaluation) do
    FacetConfidenceEvaluation.create!(project: project, issue: issue, status: "labeling",
      corpus_path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH,
      corpus_digest: FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", source_revision: "intent-sha", created_by: owner)
  end

  def judgment_for(corpus_case)
    expected = corpus_case.fetch("expected")
    {
      verdict: expected.fetch("status"), intent_band: expected.fetch("intent_band"),
      technical_band: expected.fetch("technical_band"), readiness: expected.fetch("readiness"),
      cited_evidence_reference: (expected["must_cite"] || corpus_case.fetch("evidence").map { |item| item.fetch("reference") }).first,
      reason: "Blinded reading of the case evidence."
    }
  end

  def freeze_evaluation!
    evaluation.corpus.cases.each do |corpus_case|
      FacetConfidence::CloseoutEvaluation::RecordLabel.call(
        evaluation: evaluation, actor: owner, case_id: corpus_case.fetch("id"), judgment: judgment_for(corpus_case)
      )
    end
    expect(FacetConfidence::CloseoutEvaluation::FreezeLabels.call(evaluation: evaluation, actor: owner)).to be_success
  end

  def original_judgment
    evaluation.labels.find_by!(case_id: "FC-CORPUS-01").attributes.slice(
      "verdict", "intent_band", "technical_band", "readiness", "cited_evidence_reference", "reason"
    )
  end

  def revise!(actor: owner)
    described_class.call(evaluation: evaluation, actor: actor, case_id: "FC-CORPUS-01",
      judgment: judgment_for(evaluation.corpus.find_case("FC-CORPUS-01")).merge(
        intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold", readiness: "ready",
        reason: "After seeing the frozen expectation, I reassessed the evidence."
      ), revision_reason: "I had overlooked the recorded technical validation.")
  end

  it "appends a correction while preserving the original blinded label and measures" do
    freeze_evaluation!
    original = original_judgment
    result = revise!

    expect(result).to be_success
    label = evaluation.labels.find_by!(case_id: "FC-CORPUS-01")
    expect(label.attributes.slice(*original.keys)).to eq(original)
    expect(label.revisions.sole).to have_attributes(revised_by: owner,
      revision_reason: "I had overlooked the recorded technical validation.")
    report_case = evaluation.reload.report.fetch("cases").find { |entry| entry.fetch("case_id") == "FC-CORPUS-01" }
    expect(report_case.fetch("revisions").sole).to include("revision_reason" => "I had overlooked the recorded technical validation.")
    expect(evaluation.report.dig("measures", "readiness_divergences", "count")).to eq(0)
  end

  it "refuses a correction before freeze or from another operator" do
    before_freeze = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: judgment_for(evaluation.corpus.find_case("FC-CORPUS-01")), revision_reason: "Correction")
    expect(before_freeze).not_to be_success
    expect(before_freeze.error).to include("frozen")

    freeze_evaluation!
    other_judge = revise!(actor: member)
    expect(other_judge).not_to be_success
    expect(other_judge.error).to include("sole reference judge")
  end
end
