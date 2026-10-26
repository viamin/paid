# frozen_string_literal: true

require "rails_helper"

# A post-unblinding correction is separate evidence: it must retain the
# blinded judgment and record why the judge changed their view.
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
      corpus_path:, corpus_digest: FacetConfidence::Corpus.new(path: corpus_path).content_digest,
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
      reason: "After unblinding, I gave the prototype evidence more weight."
    }
  end

  it "appends a reasoned correction after unblinding without changing the original judgment" do
    result = described_class.call(evaluation:, actor: owner, case_id: label.case_id, judgment: revision)

    expect(result).to be_success
    label.reload
    expect(label).to have_attributes(verdict: "completed", intent_band: "below_threshold",
      technical_band: "below_threshold", readiness: "not_ready", reason: "Original blinded judgment.")
    expect(label.revision).to include("verdict" => "completed", "intent_band" => "at_or_above_threshold",
      "technical_band" => "at_or_above_threshold", "readiness" => "ready",
      "cited_evidence_reference" => "sync-spike-note", "reason" => revision[:reason],
      "recorded_by" => owner.email)
    report_case = evaluation.reload.report.fetch("cases").find { |entry| entry.fetch("case_id") == label.case_id }
    expect(report_case.dig("revision", "reason")).to eq(revision[:reason])
    expect(evaluation.report_markdown).to include("Post-unblinding correction")
  end

  it "rejects a second correction, another operator, invalid citations, and a missing reason" do
    expect(described_class.call(evaluation:, actor: owner, case_id: label.case_id, judgment: revision)).to be_success
    expect(described_class.call(evaluation:, actor: owner, case_id: label.case_id, judgment: revision)).not_to be_success
    expect(described_class.call(evaluation:, actor: member, case_id: label.case_id, judgment: revision)).not_to be_success
    expect(described_class.call(evaluation:, actor: owner, case_id: "FC-CORPUS-02",
      judgment: revision.merge(cited_evidence_reference: "not-in-case"))).not_to be_success
    expect(described_class.call(evaluation:, actor: owner, case_id: "FC-CORPUS-03",
      judgment: revision.merge(reason: " "))).not_to be_success
  end
end
