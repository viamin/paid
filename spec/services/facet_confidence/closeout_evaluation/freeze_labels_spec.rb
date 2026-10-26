# frozen_string_literal: true

require "rails_helper"

# Freezing the blinded reference-judgment set of a facet-confidence closeout
# evaluation and compiling the reproducible report that returns to the
# originating Inbox item: full-coverage requirement, corpus-digest recheck,
# judgment-vs-frozen-expectation measures, and citation compliance.
# @spec FACET-CONFIDENCE-021
RSpec.describe FacetConfidence::CloseoutEvaluation::FreezeLabels do
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

  # A judgment re-deriving the case's frozen expectation, citing the evidence
  # the expectation requires (falling back to the first reference).
  def judgment_for(corpus_case)
    expected = corpus_case.fetch("expected")
    references = corpus_case.fetch("evidence").map { |item| item.fetch("reference") }
    {
      verdict: expected.fetch("status"),
      intent_band: expected.fetch("intent_band"),
      technical_band: expected.fetch("technical_band"),
      readiness: expected.fetch("readiness"),
      cited_evidence_reference: (expected["must_cite"] || references).first,
      reason: "Re-derived from the cited statements."
    }
  end

  def label!(case_id, judgment)
    FacetConfidence::CloseoutEvaluation::RecordLabel.call(
      evaluation: evaluation, actor: owner, case_id: case_id, judgment: judgment
    )
  end

  def label_all!
    evaluation.corpus.cases.each { |corpus_case| label!(corpus_case.fetch("id"), judgment_for(corpus_case)) }
  end

  it "freezes the full reference set and compiles the report against the frozen expectations" do
    label_all!

    result = described_class.call(evaluation: evaluation, actor: owner)

    expect(result).to be_success
    evaluation.reload
    expect(evaluation).to be_frozen
    expect(evaluation.labels_frozen_at).to be_present
    expect(evaluation.report["originating_closeout"]).to include("work_item" => 4323, "source_revision" => "intent-sha")
    expect(evaluation.report["provenance"]).to include("corpus_version" => "facet-confidence-corpus-v1",
      "rubric_version" => "facet-confidence-v1", "model_version" => "claude-sonnet-4-6")
    expect(evaluation.report["measures"]["readiness_divergences"]["count"]).to eq(0)
    expect(evaluation.report["measures"]["citation_violations"]["count"]).to eq(0)
    expect(evaluation.report["cases"].length).to eq(8)
    expect(evaluation.report_markdown).to include("FC-CORPUS-01").and include("80/80")
  end

  it "measures divergences and citation violations instead of hiding them" do
    evaluation.corpus.cases.each do |corpus_case|
      case_id = corpus_case.fetch("id")
      if case_id == "FC-CORPUS-01"
        # Judge the tentative-exploration case internally consistently but
        # opposite to its frozen expectation.
        label!(case_id, judgment_for(corpus_case)
          .merge(readiness: "ready", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold"))
      elsif case_id == "FC-CORPUS-02"
        # Cite the superseded statement the frozen expectation forbids.
        label!(case_id, judgment_for(corpus_case).merge(cited_evidence_reference: "early-hover-statement"))
      else
        label!(case_id, judgment_for(corpus_case))
      end
    end

    result = described_class.call(evaluation: evaluation, actor: owner)

    expect(result).to be_success
    measures = evaluation.reload.report["measures"]
    expect(measures["readiness_divergences"]).to include("count" => 1, "cases" => [ "FC-CORPUS-01" ])
    expect(measures["intent_band_divergences"]).to include("count" => 1)
    expect(measures["citation_violations"]).to include("count" => 1, "cases" => [ "FC-CORPUS-02" ])
    fc01 = evaluation.report["cases"].find { |entry| entry["case_id"] == "FC-CORPUS-01" }
    expect(fc01["divergences"]).to include("intent_band", "readiness")
  end

  it "refuses to freeze while any case is unlabeled or skipped" do
    label!("FC-CORPUS-01", judgment_for(evaluation.corpus.find_case("FC-CORPUS-01")))
    FacetConfidence::CloseoutEvaluation::RecordLabel.call(evaluation: evaluation, actor: owner,
      case_id: "FC-CORPUS-02", judgment: nil)

    result = described_class.call(evaluation: evaluation, actor: owner)

    expect(result).not_to be_success
    expect(result.error).to include("labeled").and include("skipped")
    expect(evaluation.reload).to be_labeling
    expect(evaluation.labels_frozen_at).to be_nil
  end

  it "refuses a freeze by anyone other than the operator who started the evaluation" do
    label_all!

    result = described_class.call(evaluation: evaluation, actor: member)

    expect(result).not_to be_success
    expect(result.error).to include("sole reference judge")
    expect(evaluation.reload).to be_labeling
  end

  it "refuses a rival freeze that committed behind a stale labeling read" do
    # The two-tab double-submit mirror of the RecordLabel race: both requests
    # loaded the evaluation while it was still labeling; the first froze the
    # set and compiled the report, and only afterwards does the stale request
    # reach its own freeze. The frozen state must be re-checked under the
    # evaluation row lock so an already-frozen set — and its compiled report
    # and freeze timestamp — is never overwritten.
    label_all!
    stale = FacetConfidenceEvaluation.find(evaluation.id)
    expect(described_class.call(evaluation: evaluation, actor: owner)).to be_success
    frozen_at = evaluation.reload.labels_frozen_at

    result = described_class.call(evaluation: stale, actor: owner)

    expect(result).not_to be_success
    expect(result.error).to include("already frozen")
    expect(evaluation.reload.labels_frozen_at).to eq(frozen_at)
  end

  it "refuses to freeze against a changed corpus manifest" do
    label_all!
    evaluation.update!(corpus_digest: "changed-digest")

    result = described_class.call(evaluation: evaluation, actor: owner)

    expect(result).not_to be_success
    expect(result.error).to include("corpus manifest changed")
    expect(evaluation.reload).to be_labeling
  end

  it "keeps the frozen report unchanged when a later correction is recorded" do # @spec FACET-CONFIDENCE-022
    label_all!
    described_class.call(evaluation: evaluation, actor: owner)
    frozen_report = evaluation.reload.report.deep_dup

    result = FacetConfidence::CloseoutEvaluation::ReviseLabel.call(
      evaluation: evaluation, actor: owner, case_id: "FC-CORPUS-01",
      judgment: judgment_for(evaluation.corpus.find_case("FC-CORPUS-01")).merge(reason: "Corrected after unblinding.")
    )

    expect(result).to be_success
    expect(evaluation.reload.report).to eq(frozen_report)
  end
end
