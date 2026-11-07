# frozen_string_literal: true

require "rails_helper"

# Reconciling a frozen facet-confidence closeout-evaluation report against a
# merged typed prerequisite notification: the evaluation's own occurrence is
# judged at the revision it assessed, while every other occurrence keeps the
# sufficient or stale evidence recorded against its own source issue's
# current revision — a merged foreign occurrence is never re-pegged to this
# evaluation's revision.
# @spec FACET-CONFIDENCE-023
# @spec PARTIAL-CLOSEOUT-042
RSpec.describe FacetConfidence::CloseoutEvaluation::ReconcileReport do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:foreign_issue) { create(:issue, project: project, github_number: 8801) }
  let(:evaluation) do
    corpus_path = FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH
    FacetConfidenceEvaluation.create!(project: project, issue: issue, status: "frozen",
      corpus_path: corpus_path,
      corpus_digest: FacetConfidence::Corpus.new(path: corpus_path).content_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", source_revision: "own-sha", created_by: owner,
      labels_frozen_at: 1.hour.ago, report: { "cases" => [] }, report_markdown: "# Facet-confidence report")
  end
  let(:own_occurrence) do
    { "identity" => "own-identity", "criterion" => "Independent evaluation",
      "workflow" => FacetConfidence::CloseoutEvaluation::InboxEscalation::WORKFLOW,
      "source_revision" => "own-sha", "source_issue_number" => issue.github_number }
  end
  # Merged foreign occurrence preserved from another run's attribution
  # (PartialCloseouts::Reconcile): its evidence belongs to another source
  # issue, already evaluated at that issue's own revision.
  let(:foreign_occurrence) do
    { "identity" => "foreign-identity", "criterion" => "Independent evaluation",
      "workflow" => FacetConfidence::CloseoutEvaluation::InboxEscalation::WORKFLOW,
      "source_revision" => "foreign-sha", "source_issue_number" => foreign_issue.github_number }
  end
  let(:foreign_submission) do
    { "submission_id" => "facet-confidence-evaluation-9091-foreign-identity",
      "prerequisite_identity" => "foreign-identity", "evidence_type" => "facet_confidence_evaluation",
      "evaluation_id" => 9091, "report_digest" => "foreign-report-digest", "actor_id" => owner.id,
      "submitted_at" => 2.hours.ago.iso8601, "validated_at" => 2.hours.ago.iso8601,
      "source_revision" => "foreign-sha", "outcome" => "sufficient",
      "reason" => "Frozen facet-confidence evaluation report recorded for this prerequisite occurrence." }
  end
  let!(:notification) do
    create(:notification, :error, account: account, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      metadata: {
        "workflow" => FacetConfidence::CloseoutEvaluation::InboxEscalation::WORKFLOW,
        "prerequisites" => [ own_occurrence, foreign_occurrence ],
        "evidence_submissions" => [ foreign_submission ]
      })
  end

  before do
    allow(PartialCloseouts::Assessment).to receive(:source_revision_for).with(issue).and_return("own-sha")
  end

  it "releases the notification when every occurrence holds current evidence at its own revision" do
    allow(PartialCloseouts::Assessment).to receive(:source_revision_for).with(foreign_issue).and_return("foreign-sha")

    result = described_class.call(evaluation:)

    expect(result.reconciled).to eq(1)
    expect(result.stale).to eq(0)
    expect(result.notification_ids).to eq([ notification.id ])
    submissions = notification.reload.metadata.fetch("evidence_submissions")
    own = submissions.find { |submission| submission["prerequisite_identity"] == "own-identity" }
    expect(own).to include("outcome" => "sufficient", "evaluation_id" => evaluation.id, "source_revision" => "own-sha")
    expect(submissions.find { |submission| submission["prerequisite_identity"] == "foreign-identity" }).to eq(foreign_submission)
    expect(notification.resolved_at).to be_present
    expect(notification.metadata.fetch("released_by")).to eq("facet_confidence_evaluation")
  end

  it "retains the hold when the foreign occurrence's evidence is stale at its own revision" do
    allow(PartialCloseouts::Assessment).to receive(:source_revision_for).with(foreign_issue).and_return("foreign-sha-2")

    result = described_class.call(evaluation:)

    expect(result.reconciled).to eq(1)
    expect(result.stale).to eq(0)
    submissions = notification.reload.metadata.fetch("evidence_submissions")
    expect(submissions.find { |submission| submission["prerequisite_identity"] == "own-identity" })
      .to include("outcome" => "sufficient")
    expect(submissions.find { |submission| submission["prerequisite_identity"] == "foreign-identity" })
      .to include("outcome" => "sufficient", "source_revision" => "foreign-sha")
    expect(notification).to be_active
    expect(notification.resolved_at).to be_nil
  end

  it "retains the hold when an open external occurrence has matching evidence" do
    target_project = create(:project, account:, owner: "upstream", repo: "dependency")
    create(:issue, project: target_project, github_number: 91, github_state: "open", paid_state: "in_progress")
    external_occurrence = { "identity" => "external-identity", "criterion" => "Upstream completion",
      "kind" => "external", "workflow" => FacetConfidence::CloseoutEvaluation::InboxEscalation::WORKFLOW,
      "source_revision" => "own-sha", "source_issue_number" => issue.github_number,
      "external_dependency" => { "owner" => "upstream", "repo" => "dependency", "number" => 91 } }
    external_submission = { "submission_id" => "external-evidence", "prerequisite_identity" => "external-identity",
      "source_revision" => "own-sha", "outcome" => "sufficient" }
    notification.update!(metadata: notification.metadata.merge(
      "prerequisites" => [ own_occurrence, external_occurrence ], "evidence_submissions" => [ external_submission ]
    ))

    result = described_class.call(evaluation:)

    expect(result.reconciled).to eq(1)
    expect(notification.reload.metadata.fetch("evidence_submissions").find { |submission| submission["submission_id"] == "external-evidence" })
      .to eq(external_submission)
    expect(notification).to be_active
    expect(notification.resolved_at).to be_nil
  end
end
