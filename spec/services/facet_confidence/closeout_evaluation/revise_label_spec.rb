# frozen_string_literal: true

require "rails_helper"

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
      model_version: "claude-sonnet-4-6", created_by: owner)
  end
  let!(:label) do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", verdict: "completed",
      intent_band: "below_threshold", technical_band: "below_threshold", readiness: "not_ready",
      cited_evidence_reference: "sync-sketch-statement", reason: "Original blinded reading.", recorded_by: owner,
      recorded_at: Time.current)
  end
  let(:judgment) do
    { verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: "sync-sketch-statement", reason: "Unblinded correction." }
  end

  it "appends a judge-bound correction without mutating the frozen label" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: label.case_id, judgment: judgment)

    expect(result).to be_success
    expect(label.reload).to have_attributes(intent_band: "below_threshold", readiness: "not_ready", reason: "Original blinded reading.")
    expect(result.revision).to have_attributes(**judgment, revised_by: owner)
  end

  it "rejects a correction by someone other than the reference judge" do
    result = described_class.call(evaluation: evaluation, actor: member, case_id: label.case_id, judgment: judgment)

    expect(result).not_to be_success
    expect(evaluation.label_revisions).to be_empty
  end
end
