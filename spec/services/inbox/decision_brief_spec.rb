# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::DecisionBrief do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def entry(kind, **overrides)
    Inbox::Queue::Entry.new(**{
      id: "#{kind}:1", kind:, project:, issue: nil, record: nil,
      waiting_since: Time.current, questions: [], tasks: [],
      summary_text: "A current check needs your attention.", title_text: "Improve exports",
      action_url: nil
    }.merge(overrides))
  end

  # @spec OPERATOR-INBOX-027
  it "keeps a grounded product question separate from its evidence-backed recommendation" do
    brief = described_class.call(entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      questions: [ { "question" => "Which cache should exports use?", "recommendation" => "Redis",
                     "rationale" => "Existing workers use it.", "evidence_references" => [ "worker configuration" ] } ]))

    expect(brief.to_h).to include(
      decision: "Which cache should exports use?", recommendation: "Redis",
      recommendation_reason: "Existing workers use it.", primary_action: "Answer the question"
    )
    expect(brief.unknown).to be_nil
  end

  # @spec OPERATOR-INBOX-027
  it "asks one focused question when a product recommendation has no evidence" do
    brief = described_class.call(entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, questions: [ "Which cache should exports use?" ]))

    expect(brief.recommendation).to be_nil
    expect(brief.unknown).to eq("Which cache should exports use?")
  end

  # @spec OPERATOR-INBOX-027
  it "uses the persisted remediation rather than inventing an action-required recommendation" do
    brief = described_class.call(entry(Inbox::Queue::ACTION_REQUIRED_KIND,
      tasks: [ "Grant the missing permission" ], summary_text: "A credential is unavailable."))

    expect(brief.to_h).to include(recommendation: "Grant the missing permission",
      waiting_work: "Work is waiting for the required remediation.", primary_action: "Complete remediation")
  end

  # @spec OPERATOR-INBOX-027
  it "describes manual review and partial closeout as distinct operator decisions" do
    manual = described_class.call(entry(Inbox::Queue::MANUAL_REVIEW_KIND, summary_text: "Automation stopped after review."))
    closeout = described_class.call(entry(Inbox::Queue::PARTIAL_CLOSEOUT_KIND,
      tasks: [ "Verify the production result" ], summary_text: "A merged change left one criterion open."))

    expect(manual.to_h).to include(decision: "Choose whether and how Paid should resume.", primary_action: "Review recovery")
    expect(closeout.to_h).to include(decision: "Choose how to finish the remaining acceptance criteria.",
      recommendation: "Verify the production result", primary_action: "Resolve remaining work")
  end
end
