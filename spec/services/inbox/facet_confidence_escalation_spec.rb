# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::FacetConfidenceEscalation do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:issue) { create(:issue, project:, github_number: 4678, paid_state: "in_progress") }
  let(:notification) do
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Internal closeout state", description: "Internal workflow prose")
  end

  before do
    create(:issue, :pull_request, project:, github_number: 4679, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)
  end

  # @spec FACET-CONFIDENCE-022
  it "presents a start action without exposing notification workflow prose" do
    escalation = described_class.for(notification: notification, project:, issue:)

    expect(escalation).to have_attributes(action: :start, title: "Evaluation needed")
    expect(escalation.explanation).to include("independently reviews every frozen test case")
    expect(escalation.explanation).not_to include("Internal workflow prose")
    expect(escalation.progress).to eq(total: 0, recorded: 0, remaining: 0, skipped: 0)
  end

  # @spec FACET-CONFIDENCE-022
  it "reports continue and freeze actions from durable evaluation progress" do
    evaluation = FacetConfidence::CloseoutEvaluation::Start.call(project:, issue:, actor: owner).evaluation
    case_id = evaluation.corpus.case_ids.first
    evaluation.labels.create!(case_id:, state: "labeled", recorded_by: owner, recorded_at: Time.current,
      verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
      readiness: "ready", cited_evidence_reference: evaluation.corpus.find_case(case_id).fetch("evidence").first.fetch("reference"),
      reason: "Recorded independently.")

    escalation = described_class.for(notification: notification, project:, issue:)
    expect(escalation).to have_attributes(action: :continue_judging)
    expect(escalation.progress).to include(recorded: 1, remaining: evaluation.corpus.case_ids.length - 1)

    evaluation.corpus.case_ids.drop(1).each do |remaining_case_id|
      evaluation.labels.create!(case_id: remaining_case_id, state: "labeled", recorded_by: owner, recorded_at: Time.current,
        verdict: "completed", intent_band: "at_or_above_threshold", technical_band: "at_or_above_threshold",
        readiness: "ready", cited_evidence_reference: evaluation.corpus.find_case(remaining_case_id).fetch("evidence").first.fetch("reference"),
        reason: "Recorded independently.")
    end

    expect(described_class.for(notification: notification, project:, issue:).action).to eq(:freeze)
  end

  # @spec FACET-CONFIDENCE-022
  it "leaves unrelated action-required notifications on the generic path" do
    notification.update!(source: "quality_auto_resume_cooldown")

    expect(described_class.for(notification: notification, project:, issue:)).to be_nil
  end
end
