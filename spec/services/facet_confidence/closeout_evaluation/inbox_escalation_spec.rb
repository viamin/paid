# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-022
RSpec.describe FacetConfidence::CloseoutEvaluation::InboxEscalation do
  let(:account) { create(:account) }
  let(:operator) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: operator) }
  let(:issue) { create(:issue, project:, github_number: 4323) }
  let(:corpus) { FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH) }
  let(:notification) do
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Remediation Required", description: "Internal workflow wording",
      metadata: { "prerequisites" => [ { "references" => [ { "key" => corpus.identity.fetch("corpus_version") } ] } ] })
  end

  def evaluation
    @evaluation ||= FacetConfidenceEvaluation.create!(project:, issue:, created_by: operator,
      corpus_path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH,
      corpus_digest: corpus.content_digest, corpus_version: corpus.identity.fetch("corpus_version"),
      rubric_version: corpus.identity.fetch("rubric_version"), model_version: corpus.identity.fetch("model_version"))
  end

  def label(case_id)
    corpus_case = evaluation.corpus.find_case(case_id)
    expected = corpus_case.fetch("expected")
    FacetConfidenceEvaluationLabel.create!(facet_confidence_evaluation: evaluation, case_id:, state: "labeled",
      recorded_by: operator, recorded_at: Time.current, verdict: expected.fetch("status"),
      intent_band: expected.fetch("intent_band"), technical_band: expected.fetch("technical_band"),
      readiness: expected.fetch("readiness"), cited_evidence_reference: corpus_case.fetch("evidence").first.fetch("reference"),
      reason: "Reviewed independently.")
  end

  it "recognizes the typed prerequisite without matching its prose" do
    expect(described_class.applicable?(notification:, issue:)).to be(true)
  end

  it "selects a state-specific action without claiming unfinished judgments are frozen" do
    expect(described_class.call(issue:).primary_action).to eq(:start)

    label(corpus.case_ids.first)
    result = described_class.call(issue:)
    expect(result).to have_attributes(primary_action: :continue, title: "More evaluation judgments are needed")

    corpus.case_ids.drop(1).each { |case_id| label(case_id) }
    expect(described_class.call(issue:).primary_action).to eq(:freeze)

    evaluation.update!(status: "frozen", labels_frozen_at: Time.current)
    expect(described_class.call(issue:)).to have_attributes(primary_action: :open_report, title: "Evaluation report is ready")
  end

  it "leaves unrelated partial-closeout prerequisites on the generic path" do
    notification.update!(metadata: { "prerequisites" => [ { "references" => [ { "key" => "pilot-results-v1" } ] } ] })

    expect(described_class.applicable?(notification:, issue:)).to be(false)
  end
end
