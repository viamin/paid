# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-022
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseLabel do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:member) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:issue) { create(:issue, project:, github_number: 4323) }
  let(:evaluation) do
    FacetConfidenceEvaluation.create!(project:, issue:, status: "frozen", labels_frozen_at: Time.current,
      corpus_path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH,
      corpus_digest: FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", created_by: owner)
  end
  let!(:label) do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed",
      intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded reason.",
      recorded_by: owner, recorded_at: Time.current)
  end
  let(:correction) do
    { verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-sketch-statement", reason: "Post-unblinding correction." }
  end

  it "appends a reasoned correction without replacing the frozen label" do
    result = described_class.call(evaluation:, actor: owner, case_id: label.case_id, judgment: correction)

    expect(result).to be_success
    label.reload
    expect(label).to have_attributes(verdict: "completed", intent_band: "below_threshold", reason: "Original blinded reason.")
    expect(label.revision).to have_attributes(**correction, recorded_by: owner)
  end

  it "rejects a correction by someone other than the sole judge" do
    result = described_class.call(evaluation:, actor: member, case_id: label.case_id, judgment: correction)

    expect(result).not_to be_success
    expect(result.error).to include("sole reference judge")
    expect(label.reload.revision).to be_nil
  end

  it "rejects a second correction" do
    described_class.call(evaluation:, actor: owner, case_id: label.case_id, judgment: correction)

    result = described_class.call(evaluation:, actor: owner, case_id: label.case_id, judgment: correction)

    expect(result).not_to be_success
    expect(result.error).to include("already has a correction")
  end
end
