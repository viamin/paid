# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-022 @spec OPERATOR-INBOX-002L
RSpec.describe Inbox::ActionRequiredWorkflow do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, github_number: 4323) }
  let(:notification) do
    create(:notification, :error, account:, subject: issue, blocking: true,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
      metadata: { "workflow" => { "type" => "facet_confidence_closeout_evaluation" } })
  end

  it "uses typed metadata rather than notification prose" do
    workflow = described_class.call(notification:)

    expect(workflow).to have_attributes(title: "Human evaluation required", action_label: "Start evaluation",
      recorded: 0, remaining: 8)
    expect(workflow.explanation).to include("must independently review each frozen test case")
    expect(workflow.explanation).not_to include("corpus", "blinded reference judgments")
  end

  it "moves from continuing judgments to freezing and the completed report" do
    corpus = FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH)
    evaluation = FacetConfidenceEvaluation.create!(project:, issue:, created_by: user, status: "labeling",
      corpus_path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH,
      corpus_digest: corpus.content_digest, **corpus.identity.symbolize_keys)
    corpus_case = evaluation.corpus.cases.first
    create_label(evaluation, corpus_case.fetch("id"))

    expect(described_class.call(notification:).action_label).to eq("Continue judging")

    evaluation.corpus.case_ids.drop(1).each do |case_id|
      create_label(evaluation, case_id)
    end
    expect(described_class.call(notification:).action_label).to eq("Freeze judgments")

    evaluation.update!(status: "frozen", labels_frozen_at: Time.current, report: {})
    expect(described_class.call(notification:).action_label).to eq("View evaluation report")
  end

  def create_label(evaluation, case_id)
    evaluation.labels.create!(case_id:, state: "labeled", verdict: "completed",
      intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold", readiness: "ready",
      cited_evidence_reference: "issue:test", reason: "Independent review.", recorded_by: user,
      recorded_at: Time.current)
  end

  it "returns no workflow for an unknown type" do
    notification.metadata = { "workflow" => { "type" => "unknown" } }

    expect(described_class.call(notification:)).to be_nil
  end
end
