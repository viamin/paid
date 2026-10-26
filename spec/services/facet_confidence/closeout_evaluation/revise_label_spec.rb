# frozen_string_literal: true

require "rails_helper"

# Post-unblinding corrections retain the blinded original and append an
# attributable, reasoned revision rather than rewriting reference evidence.
# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseLabel do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:corpus_path) { FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH }
  let(:evaluation) do
    FacetConfidenceEvaluation.create!(project:, issue:, status: "frozen", labels_frozen_at: Time.current,
      corpus_path:, corpus_digest: FacetConfidence::Corpus.new(path: corpus_path).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", source_revision: "intent-sha", created_by: owner)
  end
  let!(:label) do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed",
      intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded judgment.",
      recorded_by: owner, recorded_at: Time.current)
  end
  let(:judgment) do
    { verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-sketch-statement", reason: "After unblinding, corrected judgment." }
  end

  it "preserves the frozen original and appends a separately reasoned revision" do
    result = described_class.call(evaluation:, actor: owner, case_id: label.case_id, judgment:)

    expect(result).to be_success
    expect(label.reload).to have_attributes(intent_band: "below_threshold", readiness: "not_ready")
    expect(result.revision).to include(judgment.stringify_keys, "recorded_by_id" => owner.id)
    expect(evaluation.reload.report.fetch("post_unblinding_revisions").fetch(label.case_id).first).to include(judgment.stringify_keys)
    expect(evaluation.report_markdown).to include("Post-unblinding corrections").and include(judgment.fetch(:reason))
  end

  it "requires the sole judge, a frozen set, a case citation, and a reason" do
    expect(described_class.call(evaluation:, actor: member, case_id: label.case_id, judgment:)).not_to be_success
    expect(described_class.call(evaluation:, actor: owner, case_id: label.case_id,
      judgment: judgment.merge(reason: ""))).not_to be_success
    expect(described_class.call(evaluation:, actor: owner, case_id: label.case_id,
      judgment: judgment.merge(cited_evidence_reference: "not-a-case-reference"))).not_to be_success
  end
end
