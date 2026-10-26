# frozen_string_literal: true

require "rails_helper"

# The blinded judgment is immutable evidence after unblinding. A correction is
# a separate, attributed revision with its own reason; it never rewrites the
# original judgment or the report's blinded comparison.
# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::ReviseJudgment do
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
  let(:original_judgment) do
    {
      verdict: "clarification_needed", intent_band: "below_threshold", technical_band: "at_or_above_threshold",
      readiness: "not_ready", cited_evidence_reference: "sync-sketch-statement", reason: "The direction is provisional."
    }
  end
  let(:revised_judgment) do
    original_judgment.merge(verdict: "completed", intent_band: "at_or_above_threshold",
      readiness: "ready", reason: "Unblinded correction: a separate decision record resolves the direction.")
  end

  before do
    evaluation.labels.create!(case_id: "FC-CORPUS-01", state: "labeled", **original_judgment,
      recorded_by: owner, recorded_at: 1.minute.ago)
  end

  it "appends an attributed, reasoned post-unblinding revision without altering the blinded judgment" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: revised_judgment)

    expect(result).to be_success
    original = evaluation.labels.find_by!(case_id: "FC-CORPUS-01")
    expect(original).to have_attributes(**original_judgment, recorded_by: owner)
    expect(result.revision).to have_attributes(**revised_judgment, revised_by: owner)
    expect(result.revision.revised_at).to be_present
  end

  it "refuses a revision by anyone other than the authenticated reference judge" do
    result = described_class.call(evaluation: evaluation, actor: member, case_id: "FC-CORPUS-01", judgment: revised_judgment)

    expect(result).not_to be_success
    expect(result.error).to include("sole reference judge")
    expect(evaluation.judgment_revisions).to be_empty
  end

  it "requires a case-evidence citation and a distinct correction reason" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: revised_judgment.merge(cited_evidence_reference: "not-a-case-reference", reason: ""))

    expect(result).not_to be_success
    expect(result.error).to include("cited evidence").or include("reason")
    expect(evaluation.judgment_revisions).to be_empty
  end

  it "refuses revisions before unblinding" do
    evaluation.update!(status: "labeling", labels_frozen_at: nil)

    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: revised_judgment)

    expect(result).not_to be_success
    expect(result.error).to include("after the reference set is frozen")
  end
end
