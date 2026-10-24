# frozen_string_literal: true

require "rails_helper"

# Recording one blinded human reference judgment per frozen corpus case of a
# facet-confidence closeout evaluation: durable save/resume, structural
# validation (bands, readiness consistency, cited evidence), the sole-judge
# boundary, and skip semantics.
# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::RecordLabel do
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

  # A valid judgment for FC-CORPUS-01 (provisional direction: both bands below
  # threshold, not ready), citing one of that case's evidence references.
  let(:judgment) do
    {
      verdict: "completed", intent_band: "below_threshold", technical_band: "below_threshold",
      readiness: "not_ready", cited_evidence_reference: "sync-sketch-statement",
      reason: "Tentative exploration is not explicit direction; an untested spike is not demonstrated feasibility."
    }
  end

  it "records a labeled judgment for one corpus case with durable save/resume" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: judgment)

    expect(result).to be_success
    expect(result.label).to be_labeled
    expect(result.label).to have_attributes(**judgment, recorded_by: owner)
    expect(result.label.recorded_at).to be_present

    described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: judgment.merge(reason: "Reconsidered: still tentative, not committed."))

    expect(evaluation.labels.count).to eq(1)
    expect(evaluation.labels.first.reason).to eq("Reconsidered: still tentative, not committed.")
  end

  it "rejects a citation that is not one of the case's evidence references" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-02",
      judgment: judgment.merge(cited_evidence_reference: "not-a-case-reference"))

    expect(result).not_to be_success
    expect(result.error).to include("keyboard-correction")
    expect(evaluation.labels).to be_empty
  end

  it "rejects a readiness that contradicts the judged bands" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: judgment.merge(readiness: "ready"))

    expect(result).not_to be_success
    expect(result.error).to match(/readiness/i)
    expect(evaluation.labels.count).to eq(0)
  end

  it "rejects judgments outside the band and verdict vocabulary" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: judgment.merge(intent_band: "very_high"))

    expect(result).not_to be_success
    expect(result.error).to match(/intent band/i)
  end

  it "records skips that never count as labeled judgments" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: nil)

    expect(result).to be_success
    expect(result.label).to be_skipped
    expect(result.label).not_to be_labeled
    expect(evaluation.progress).to include(total: 8, labeled: 0, skipped: 1)
  end

  it "refuses recording by anyone other than the operator who started the evaluation" do
    result = described_class.call(evaluation: evaluation, actor: member, case_id: "FC-CORPUS-01", judgment: judgment)

    expect(result).not_to be_success
    expect(result.error).to include("sole reference judge")
    expect(evaluation.labels).to be_empty
  end

  it "refuses a case outside the frozen corpus" do
    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-99", judgment: judgment)

    expect(result).not_to be_success
    expect(result.error).to include("not part of the frozen corpus")
  end

  it "refuses recording after the reference set is frozen" do
    evaluation.update!(status: "frozen", labels_frozen_at: Time.current)

    result = described_class.call(evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01", judgment: judgment)

    expect(result).not_to be_success
    expect(result.error).to include("frozen")
  end

  it "refuses recording when freezing commits behind a stale labeling read" do
    # The two-tab race from review: this request loaded the evaluation while
    # it was still labeling, FreezeLabels then froze the set and compiled the
    # report, and only afterwards does the stale request reach its save. The
    # frozen state must be re-checked under the evaluation row lock, never
    # trusted from the in-memory instance.
    stale = FacetConfidenceEvaluation.find(evaluation.id)
    evaluation.update!(status: "frozen", labels_frozen_at: Time.current)

    result = described_class.call(evaluation: stale, actor: owner, case_id: "FC-CORPUS-01", judgment: judgment)

    expect(result).not_to be_success
    expect(result.error).to include("frozen")
    expect(stale.labels.count).to eq(0)
  end
end
