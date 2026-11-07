# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-027
RSpec.describe Inbox::DecisionBrief do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, owner: "acme", repo: "briefs") }

  def entry(kind:, issue: nil, questions: [], summary: "A decision is waiting.", guidance: nil, tasks: [])
    Inbox::Queue::Entry.new(
      id: "#{kind}:1", kind:, project:, issue:, record: issue, waiting_since: Time.current,
      questions:, tasks:, summary_text: summary, title_text: "Choose a cache", action_url: nil, guidance:
    )
  end

  it "uses an evidence-backed question recommendation across the brief" do
    question = {
      "question" => "Which cache should exports use?",
      "recommendation" => "Use Redis.",
      "rationale" => "It is already shared by the workers.",
      "evidence_references" => [ "Worker configuration" ]
    }
    brief = described_class.call(entry: entry(kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND, questions: [ question ]))

    expect(brief.to_h).to include(
      project: "acme/briefs",
      decision: "Which cache should exports use?",
      recommendation: "Use Redis.",
      why: "It is already shared by the workers.",
      evidence_state: "current",
      primary_action: "Use Redis."
    )
    expect(brief.list).to include(work_item: "Choose a cache", impact: "Paid is waiting for your answer.")
  end

  it "does not manufacture a recommendation for a legacy question" do
    brief = described_class.call(entry: entry(kind: Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      questions: [ "Which cache should exports use?" ]))

    expect(brief.to_h).to include(
      recommendation: nil,
      evidence_state: "unknown",
      focused_question: "Which cache should exports use?"
    )
  end

  it "discloses stale persisted guidance rather than presenting it as current" do
    issue = create(:issue, :pull_request, project:)
    brief = described_class.call(entry: entry(kind: Inbox::Queue::MERGE_APPROVAL_KIND, issue:,
      guidance: { instruction: "Review the current changes on GitHub.", heading: "Approval is stale", stale_approval: true }))

    expect(brief.to_h).to include(
      recommendation: nil,
      evidence_state: "stale",
      uncertainty: "The recorded approval is stale for the current revision."
    )
  end

  it "withholds conflicting guidance and asks one focused question" do
    brief = described_class.call(entry: entry(kind: Inbox::Queue::ACTION_REQUIRED_KIND,
      guidance: { instruction: "Rotate the credential.", evidence_state: "conflicting" }))

    expect(brief.to_h).to include(
      recommendation: nil,
      evidence_state: "conflicting",
      uncertainty: "Paid has conflicting evidence and cannot recommend an action.",
      focused_question: "What outcome should Paid pursue next?"
    )
  end
end
