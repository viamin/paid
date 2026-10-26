# frozen_string_literal: true

require "rails_helper"

# A post-unblinding correction is distinct from a blinded reference judgment:
# it preserves the original judgment and records the correcting judgment,
# reason, judge, and timestamp separately.
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
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded reading.",
      recorded_by: owner, recorded_at: Time.current)
  end
  let(:revision) do
    {
      verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-sketch-statement",
      reason: "After unblinding, I corrected my reading of the same evidence."
    }
  end

  it "appends a reasoned correction without overwriting the original blinded judgment" do
    result = described_class.call(evaluation:, actor: owner, case_id: label.case_id, judgment: revision)

    expect(result).to be_success
    expect(label.reload).to have_attributes(
      verdict: "completed", intent_band: "below_threshold", technical_band: "below_threshold",
      readiness: "not_ready", reason: "Original blinded reading.", revised_by: owner
    )
    expect(label).to have_attributes(**revision.slice(:verdict, :intent_band, :technical_band, :readiness)
      .transform_keys { |key| "revised_#{key}" })
    expect(label.revised_reason).to eq(revision[:reason])
    expect(label.revised_at).to be_present
  end

  it "refuses revisions by anyone other than the original judge" do
    result = described_class.call(evaluation:, actor: member, case_id: label.case_id, judgment: revision)

    expect(result).not_to be_success
    expect(result.error).to include("sole reference judge")
    expect(label.reload.revised_at).to be_nil
  end

  it "requires a complete, internally consistent correction and a reason" do
    result = described_class.call(evaluation:, actor: owner, case_id: label.case_id,
      judgment: revision.merge(readiness: "not_ready", reason: ""))

    expect(result).not_to be_success
    expect(result.error).to match(/readiness|reason/i)
    expect(label.reload.revised_at).to be_nil
  end
end
