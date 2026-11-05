# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-026
RSpec.describe Inbox::DecisionBrief do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def entry(kind:, **attributes)
    Inbox::Queue::Entry.new(**{
      id: "#{kind}:1",
      kind:,
      project:,
      issue: nil,
      record: nil,
      waiting_since: 2.hours.ago,
      questions: [],
      tasks: [],
      summary_text: "The current evidence needs an operator decision.",
      title_text: "Choose a release direction",
      action_url: nil
    }.merge(attributes))
  end

  it "projects a concise, deterministic brief from a partial closeout's persisted state" do
    issue = create(:issue, project:, title: "Ship import validation")
    brief = described_class.call(entry: entry(kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue:,
      tasks: [ "Awaiting security-team approval" ]))

    expect(brief.to_h).to include(
      project: project.full_name,
      work_item: "Ship import validation",
      decision: "Decide how to finish the remaining work.",
      recommendation: "Review the current acceptance assessment, then continue the remaining work or request a fresh audit.",
      why: "The current evidence needs an operator decision.",
      waiting_on: [ "Awaiting security-team approval" ],
      evidence_status: "current"
    )
  end

  it "does not invent a recommendation for a genuine product question" do
    issue = create(:issue, project:, title: "Invite teammates")
    brief = described_class.call(entry: entry(kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND, issue:,
      questions: [ "Should invitations expire after seven days?" ]))

    expect(brief.to_h).to include(
      decision: "Answer one product question.",
      recommendation: nil,
      unknown: "Paid cannot recommend an answer from the recorded evidence.",
      focused_question: "Should invitations expire after seven days?"
    )
  end

  it "discloses stale evidence instead of presenting the recommendation as certain" do
    issue = create(:issue, project:)
    assessment = PartialCloseouts::Assessment::Result.new(
      assessment: {}, criteria: [], source_revision: nil, intent_revision: nil,
      assessed_at: nil, stale: true, next_action: {}
    )
    allow(PartialCloseouts::Assessment).to receive(:call).with(issue).and_return(assessment)

    brief = described_class.call(entry: entry(kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue:), detailed: true)

    expect(brief.evidence_status).to eq("stale")
    expect(brief.recommendation).to include("fresh audit")
  end
end
