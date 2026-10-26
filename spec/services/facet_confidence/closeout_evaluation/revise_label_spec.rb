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
    FacetConfidenceEvaluationLabel.create!(facet_confidence_evaluation: evaluation, recorded_by: owner,
      case_id: "FC-CORPUS-01", state: "labeled", verdict: "unknown", intent_band: "unknown",
      technical_band: "unknown", readiness: "not_ready", cited_evidence_reference: "exploration-note",
      reason: "The original blinded judgment.", recorded_at: Time.current)
  end

  def call(actor: owner, judgment: revised_judgment, reason: "The unblinded comparison exposed missed evidence.")
    described_class.call(evaluation: evaluation, actor: actor, case_id: label.case_id, judgment: judgment, reason: reason)
  end

  def revised_judgment
    {
      verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-sketch-statement", reason: "The corrected policy assessment."
    }
  end

  it "records a reasoned post-unblinding revision without changing the frozen judgment" do
    result = call

    expect(result).to be_success
    label.reload
    expect(label.slice("verdict", "intent_band", "technical_band", "readiness", "cited_evidence_reference", "reason")).to eq(
      "verdict" => "unknown", "intent_band" => "unknown", "technical_band" => "unknown", "readiness" => "not_ready",
      "cited_evidence_reference" => "exploration-note", "reason" => "The original blinded judgment."
    )
    expect(label.revised_judgment).to include("verdict" => "completed", "readiness" => "ready",
      "reason" => "The corrected policy assessment.")
    expect(label.revised_by).to eq(owner)
    expect(label.revised_reason).to eq("The unblinded comparison exposed missed evidence.")
    expect(evaluation.reload.report.dig("cases", 0, "revision", "judgment", "verdict")).to eq("completed")
  end

  it "rejects a revision by anyone other than the reference judge" do
    result = call(actor: member)

    expect(result).not_to be_success
    expect(result.error).to include("sole reference judge")
    expect(label.reload).not_to be_revised
  end

  it "requires a reason and accepts only a structurally valid replacement judgment" do
    expect(call(reason: " ")).not_to be_success
    expect(call(judgment: revised_judgment.merge(readiness: "not_ready"))).not_to be_success
    expect(label.reload).not_to be_revised
  end
end
