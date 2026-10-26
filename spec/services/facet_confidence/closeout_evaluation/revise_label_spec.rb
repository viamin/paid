# frozen_string_literal: true

require "rails_helper"

# A post-unblinding correction is separately attributable evidence. It never
# overwrites the blinded reference judgment that the frozen report compared.
# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseLabel do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:corpus_path) { FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH }
  let(:evaluation) do
    FacetConfidenceEvaluation.create!(project: project, issue: issue, status: "frozen", labels_frozen_at: Time.current,
      corpus_path: corpus_path, corpus_digest: FacetConfidence::Corpus.new(path: corpus_path).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", source_revision: "intent-sha", created_by: owner)
  end
  let(:judgment) do
    { verdict: "completed", intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "The original blinded judgment." }
  end

  before do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", **judgment, recorded_by: owner, recorded_at: Time.current)
  end

  def call(actor: owner, case_id: "FC-CORPUS-01", judgment: revised_judgment)
    described_class.call(evaluation: evaluation, actor: actor, case_id: case_id, judgment: judgment)
  end

  def revised_judgment
    judgment.merge(intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold", readiness: "ready",
      reason: "After unblinding, the cited evidence supports a different reading.")
  end

  it "appends an attributed, reasoned revision without overwriting the blinded judgment" do
    result = call

    expect(result).to be_success
    label = evaluation.labels.find_by!(case_id: "FC-CORPUS-01")
    expect(label).to have_attributes(**judgment, revised_verdict: "completed", revised_intent_band: "at_or_above_threshold",
      revised_technical_band: "at_or_above_threshold", revised_readiness: "ready", revised_by: owner)
    expect(label.revised_at).to be_present
  end

  it "rejects revisions before unblinding, by another user, without a reason, or with inconsistent bands" do
    evaluation.update!(status: "labeling", labels_frozen_at: nil)
    expect(call).not_to be_success
    evaluation.update!(status: "frozen", labels_frozen_at: Time.current)

    expect(call(actor: member)).not_to be_success
    expect(call(judgment: revised_judgment.merge(reason: " "))).not_to be_success
    expect(call(judgment: revised_judgment.merge(readiness: "not_ready"))).not_to be_success
  end

  it "rejects a second correction so the report has one unambiguous post-unblinding revision" do
    expect(call).to be_success

    expect(call).not_to be_success
  end
end
