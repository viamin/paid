# frozen_string_literal: true

require "rails_helper"

# Post-unblinding corrections retain the frozen blinded reference judgment and
# append separately-auditable context; they must never change the comparison
# set that was frozen against the corpus expectations.
# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseLabel do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:corpus_path) { FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH }
  let(:evaluation) do
    FacetConfidenceEvaluation.create!(project: project, issue: issue, status: "labeling",
      corpus_path: corpus_path,
      corpus_digest: FacetConfidence::Corpus.new(path: corpus_path).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", source_revision: "intent-sha", created_by: owner)
  end

  def judgment_for(corpus_case)
    expected = corpus_case.fetch("expected")
    references = corpus_case.fetch("evidence").map { |item| item.fetch("reference") }
    {
      verdict: expected.fetch("status"),
      intent_band: expected.fetch("intent_band"),
      technical_band: expected.fetch("technical_band"),
      readiness: expected.fetch("readiness"),
      cited_evidence_reference: (expected["must_cite"] || references).first,
      reason: "Blinded reading of the cited statements."
    }
  end

  def freeze!
    evaluation.corpus.cases.each do |corpus_case|
      FacetConfidence::CloseoutEvaluation::RecordLabel.call(
        evaluation: evaluation, actor: owner, case_id: corpus_case.fetch("id"), judgment: judgment_for(corpus_case)
      )
    end
    expect(FacetConfidence::CloseoutEvaluation::FreezeLabels.call(evaluation: evaluation, actor: owner)).to be_success
  end

  it "retains the original frozen judgment and records a reasoned correction separately" do
    freeze!
    label = evaluation.labels.find_by!(case_id: "FC-CORPUS-01")
    original = label.attributes.slice("verdict", "intent_band", "technical_band", "readiness", "cited_evidence_reference", "reason")
    correction = judgment_for(evaluation.corpus.find_case("FC-CORPUS-01")).merge(
      verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", reason: "After unblinding, I corrected my reading of the evidence."
    )

    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, judgment: correction)

    expect(result).to be_success
    label.reload
    expect(label.attributes.slice("verdict", "intent_band", "technical_band", "readiness", "cited_evidence_reference", "reason")).to eq(original)
    expect(evaluation.reload.report.fetch("revisions").fetch(label.case_id)).to include("verdict" => "completed", "readiness" => "ready", "reason" => correction[:reason], "recorded_by" => owner.email)
    report_case = evaluation.reload.report.fetch("cases").find { |entry| entry.fetch("case_id") == label.case_id }
    expect(report_case.fetch("judgment")).to include("verdict" => original.fetch("verdict"))
    expect(report_case.fetch("revision")).to include("verdict" => "completed", "reason" => correction[:reason])
  end

  it "rejects a correction before unblinding, by another operator, without a reason, or after one is recorded" do
    judgment = judgment_for(evaluation.corpus.find_case("FC-CORPUS-01"))
    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: judgment)).not_to be_success

    freeze!
    expect(described_class.call(evaluation: evaluation, actor: member, case_id: "FC-CORPUS-01", judgment: judgment)).not_to be_success
    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: judgment.merge(reason: " "))).not_to be_success
    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: judgment)).to be_success
    expect(described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: judgment)).not_to be_success
  end
end
