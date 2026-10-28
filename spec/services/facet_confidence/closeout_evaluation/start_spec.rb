# frozen_string_literal: true

require "rails_helper"

# Starting the persisted facet-confidence closeout evaluation from the
# partial-closeout Inbox entry point: one evaluation per originating closeout,
# pinned to the shipped frozen corpus, and blocked while the closeout records
# unresolved blockers.
# @spec FACET-CONFIDENCE-020 @spec FACET-CONFIDENCE-022
RSpec.describe FacetConfidence::CloseoutEvaluation::Start do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: owner) }
  let(:issue) { create(:issue, project: project, github_number: 4323) }
  let(:corpus_path) { FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH }
  let(:corpus_digest) { FacetConfidence::Corpus.new(path: corpus_path).content_digest }

  def ready_status
    instance_double(Issues::CloseoutStatus::Result, blockers: [])
  end

  def blocked_status
    blocker = Issues::CloseoutStatus::Blocker.new(code: :unmet_prerequisites, message: "#4316 is open",
      evidence: { "prerequisites" => [ "#4316" ] }, recovery: "Complete #4316, then refresh this closeout.")
    instance_double(Issues::CloseoutStatus::Result, blockers: [ blocker ])
  end

  it "starts one persisted evaluation pinned to the shipped frozen corpus identity" do
    result = described_class.call(project: project, issue: issue, actor: owner, status: ready_status)

    expect(result).to be_success
    expect(result.resumed).to be(false)
    expect(result.evaluation).to have_attributes(project: project, issue: issue, status: "labeling",
      corpus_path: corpus_path, corpus_digest: corpus_digest,
      corpus_version: "facet-confidence-corpus-v1", rubric_version: "facet-confidence-v1",
      model_version: "claude-sonnet-4-6", created_by: owner)
    expect(result.evaluation.corpus_case_ids).to include("FC-CORPUS-01", "FC-CORPUS-08")
  end

  it "records the originating closeout source revision" do
    assessment = instance_double(PartialCloseouts::Assessment::Result, source_revision: "intent-sha")
    allow(PartialCloseouts::Assessment).to receive(:call).with(issue).and_return(assessment)

    result = described_class.call(project: project, issue: issue, actor: owner, status: ready_status)

    expect(result.evaluation.source_revision).to eq("intent-sha")
  end

  it "resumes the same evaluation for the same corpus digest on repeated starts" do
    first = described_class.call(project: project, issue: issue, actor: owner, status: ready_status)
    second = described_class.call(project: project, issue: issue, actor: owner, status: ready_status)

    expect(second).to be_success
    expect(second.resumed).to be(true)
    expect(second.evaluation.id).to eq(first.evaluation.id)
    expect(issue.facet_confidence_evaluations.count).to eq(1)
  end

  it "refuses to start while the closeout records unresolved blockers" do
    result = described_class.call(project: project, issue: issue, actor: owner, status: blocked_status)

    expect(result).not_to be_success
    expect(result.error).to include("#4316 is open")
    expect(issue.facet_confidence_evaluations).to be_empty
  end

  it "starts through its typed Action Required escalation but keeps other blockers" do
    notification = create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Independent evaluation needed", description: "Internal wording is not used by the Inbox presentation.",
      metadata: { "workflow" => FacetConfidence::CloseoutEvaluation::InboxEscalation::WORKFLOW })
    escalation = Issues::CloseoutStatus::Blocker.new(code: :human_prerequisite_notification,
      message: "The evaluation is waiting for an independent maintainer.", evidence: { "notification_id" => notification.id }, recovery: "Start evaluation.")
    unrelated = Issues::CloseoutStatus::Blocker.new(code: :unmet_prerequisites,
      message: "#4316 is open", evidence: {}, recovery: "Complete #4316.")

    result = described_class.call(project:, issue:, actor: owner,
      status: instance_double(Issues::CloseoutStatus::Result, blockers: [ escalation ]))

    expect(result).to be_success

    result = described_class.call(project:, issue:, actor: owner,
      status: instance_double(Issues::CloseoutStatus::Result, blockers: [ escalation, unrelated ]))

    expect(result).not_to be_success
    expect(result.error).to include("#4316 is open")
  end

  it "refuses an originating work item outside the project" do
    other_issue = create(:issue, project: create(:project, account: account), github_number: 99)

    result = described_class.call(project: project, issue: other_issue, actor: owner, status: ready_status)

    expect(result).not_to be_success
    expect(result.error).to include("must belong to this project")
    expect(other_issue.facet_confidence_evaluations).to be_empty
  end

  it "refuses an unauthenticated actor" do
    result = described_class.call(project: project, issue: issue, actor: nil, status: ready_status)

    expect(result).not_to be_success
    expect(issue.facet_confidence_evaluations).to be_empty
  end
end
