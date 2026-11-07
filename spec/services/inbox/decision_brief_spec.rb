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
    brief = described_class.call(entry: entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      questions: [ { "question" => "Which cache should exports use?", "recommendation" => "Redis",
                     "rationale" => "Existing workers use it.", "evidence_references" => [ "worker configuration" ] } ]))

    expect(brief.to_h).to include(
      decision: "Which cache should exports use?", recommendation: "Redis",
      recommendation_reason: "Existing workers use it.", primary_action: "Answer the question"
    )
    expect(brief.unknown).to be_nil
    expect(brief.list_summary).to eq("Which cache should exports use? — Product direction is needed before work can continue.")
  end

  # @spec OPERATOR-INBOX-027
  it "bounds the list summary so long agent questions keep list rows scannable" do
    long_question = ("Which cache should exports use for the reporting pipeline? " * 5).strip
    brief = described_class.call(entry: entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, questions: [ long_question ]))

    expect(brief.list_summary.length).to eq(220)
    expect(brief.list_summary).to start_with("Which cache should exports use")
    expect(brief.list_summary).to end_with("...")
  end

  # @spec OPERATOR-INBOX-027
  it "uses cited evidence when a grounded recommendation has no recorded rationale" do
    brief = described_class.call(entry: entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND,
      questions: [ { "question" => "Which cache should exports use?", "recommendation" => "Redis",
                     "evidence_references" => [ "worker configuration", "deployment notes" ] } ]))

    expect(brief.recommendation_reason).to eq("Supported by: worker configuration; deployment notes.")
  end

  # @spec OPERATOR-INBOX-027
  it "asks one focused question when a product recommendation has no evidence" do
    brief = described_class.call(entry: entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, questions: [ "Which cache should exports use?" ]))

    expect(brief.recommendation).to be_nil
    expect(brief.unknown).to eq("Which cache should exports use?")
  end

  # @spec OPERATOR-INBOX-027
  it "uses the persisted remediation rather than inventing an action-required recommendation" do
    brief = described_class.call(entry: entry(Inbox::Queue::ACTION_REQUIRED_KIND,
      tasks: [ "Grant the missing permission" ], summary_text: "A credential is unavailable."))

    expect(brief.to_h).to include(recommendation: "Grant the missing permission",
      waiting_work: "Work is waiting for the required remediation.", primary_action: "Complete remediation")
  end

  # @spec OPERATOR-INBOX-027
  it "describes manual review and partial closeout as distinct operator decisions" do
    manual = described_class.call(entry: entry(Inbox::Queue::MANUAL_REVIEW_KIND, summary_text: "Automation stopped after review."))
    prerequisite = create(:issue, project:, github_number: 512, title: "Verify the production result")
    blocked_issue = create(:issue, project:, github_number: 511)
    create(:issue_dependency, issue: blocked_issue, depends_on_issue: prerequisite)
    closeout = described_class.call(entry: entry(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue: blocked_issue,
      tasks: [ "#512" ], summary_text: "Paid recorded no no-code-required declaration and no merged PR; paid_state is new. " \
        "Unresolved prerequisite work (#512) must be resolved or linked before continuation."))

    expect(manual.to_h).to include(decision: "Choose whether and how Paid should resume.", primary_action: "Review recovery")
    expect(closeout.to_h).to include(decision: "Choose how to finish the remaining acceptance criteria.",
      changed: "This issue still has remaining acceptance work.",
      recommendation: "Resolve the prerequisite: Verify the production result.", primary_action: "Resolve remaining work")
    expect(closeout.to_h.to_json).not_to include("#512")
    expect(closeout.to_h.to_json).not_to include("paid_state")
  end

  # @spec OPERATOR-INBOX-027
  it "resolves a partial-closeout recommendation only once per brief" do
    prerequisite = create(:issue, project:, github_number: 512, title: "Verify the production result")
    blocked_issue = create(:issue, project:, github_number: 511)
    create(:issue_dependency, issue: blocked_issue, depends_on_issue: prerequisite)
    queries = []
    callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].include?("issue_dependencies") }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.call(entry: entry(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue: blocked_issue, tasks: [ "#512" ]))
    end

    expect(queries.size).to eq(1)
  end

  # @spec OPERATOR-INBOX-027
  it "describes every queue lane with a specific decision and resulting state" do
    generic_copy = [ "Review and take the requested action.", "Review this item",
      "Paid will recheck the item after the action is recorded." ]

    Inbox::Queue::KINDS.each do |kind|
      brief = described_class.call(entry: entry(kind))

      expect(brief.decision).to be_present, kind
      expect(brief.primary_action).to be_present, kind
      expect(brief.next_state).to be_present, kind
      expect(brief.to_h.values).not_to include(*generic_copy), kind
    end
  end

  # @spec OPERATOR-INBOX-027
  it "requires the production keyword argument shape" do
    expect { described_class.call }.to raise_error(ArgumentError)
    expect { described_class.call(entry(Inbox::Queue::PLAN_REVIEW_KIND)) }.to raise_error(ArgumentError)
  end
end
