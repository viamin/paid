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
  it "grounds the goal in an approved feature intent rather than the work-item title" do
    issue = create(:issue, project:, title: "Fix the unrelated queue item")
    feature = create(:feature_intent, project:, title: "Export reliability", brief: "Exports complete without duplicate rows.",
      approved_design_revision: "a" * 40)
    create(:feature_intent_issue, feature_intent: feature, issue:)

    brief = described_class.call(entry: entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue:))

    expect(brief.to_h).to include(
      goal: "Exports complete without duplicate rows.",
      goal_source: "Approved feature intent: Export reliability",
      goal_revision: "a" * 40,
      repository_context: project.full_name
    )
    expect(brief.linked_goal_intents).to eq([
      { goal: "Exports complete without duplicate rows.", source: "Approved feature intent: Export reliability", revision: "a" * 40 }
    ])
    expect(brief.goal).not_to eq(issue.title)
  end

  # @spec OPERATOR-INBOX-027
  it "uses the root work item's released intent for a linked pull request" do
    root_issue = create(:issue, project:, title: "Root work")
    pull_request = create(:issue, :pull_request, project:, parent_issue: root_issue, title: "Implementation pull request")
    feature = create(:feature_intent, project:, brief: "Operators can export a complete report.",
      approved_design_revision: "b" * 40)
    create(:feature_intent_issue, feature_intent: feature, issue: root_issue)

    brief = described_class.call(entry: entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue: pull_request))

    expect(brief.to_h).to include(
      goal: "Operators can export a complete report.",
      goal_source: "Approved feature intent: #{feature.title}",
      goal_revision: "b" * 40
    )
  end

  # @spec OPERATOR-INBOX-027
  it "uses released intent linked directly to a pull request in a batch" do
    root_issue = create(:issue, project:, title: "Root work")
    pull_request = create(:issue, :pull_request, project:, parent_issue: root_issue, title: "Implementation pull request")
    feature = create(:feature_intent, project:, brief: "Operators can export a complete report.",
      approved_design_revision: "c" * 40)
    create(:feature_intent_issue, feature_intent: feature, issue: pull_request)
    inbox_entry = entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue: pull_request)
    expected_goal = {
      goal: "Operators can export a complete report.",
      goal_source: "Approved feature intent: #{feature.title}",
      goal_revision: "c" * 40
    }

    expect(described_class.call(entry: inbox_entry).to_h).to include(expected_goal)

    Inbox::GoalContext.preload(entries: [ inbox_entry ])

    expect(described_class.call(entry: inbox_entry).to_h).to include(expected_goal)
  end

  # @spec OPERATOR-INBOX-027
  it "prefers approved intent when direct lookup finds a newer unapproved linked design" do
    issue = create(:issue, project:)
    approved = create(:feature_intent, project:, title: "Approved exports", brief: "Exports remain complete.",
      approved_design_revision: "d" * 40, approved_revision_recorded_at: 2.days.ago)
    unapproved = create(:feature_intent, :approved_waiting_for_merge, project:, title: "Unreleased exports",
      approved_design_revision: nil, approved_revision_recorded_at: nil)
    create(:feature_intent_issue, feature_intent: approved, issue:)
    create(:feature_intent_issue, feature_intent: unapproved, issue:)

    brief = described_class.call(entry: entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue:))

    expect(brief.to_h).to include(
      goal: "Exports remain complete.",
      goal_source: "Approved feature intent: Approved exports",
      goal_revision: "d" * 40
    )
  end

  # @spec OPERATOR-INBOX-027
  it "prefers approved intent when batch lookup finds a newer unapproved linked design" do
    issue = create(:issue, project:)
    approved = create(:feature_intent, project:, title: "Approved exports", brief: "Exports remain complete.",
      approved_design_revision: "e" * 40, approved_revision_recorded_at: 2.days.ago)
    unapproved = create(:feature_intent, :approved_waiting_for_merge, project:, title: "Unreleased exports",
      approved_design_revision: nil, approved_revision_recorded_at: nil)
    create(:feature_intent_issue, feature_intent: approved, issue:)
    create(:feature_intent_issue, feature_intent: unapproved, issue:)
    inbox_entry = entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue:)

    Inbox::GoalContext.preload(entries: [ inbox_entry ])
    brief = described_class.call(entry: inbox_entry)

    expect(brief.to_h).to include(
      goal: "Exports remain complete.",
      goal_source: "Approved feature intent: Approved exports",
      goal_revision: "e" * 40
    )
  end

  # @spec OPERATOR-INBOX-027
  it "keeps one approved intent singular when it is linked to two entries in a batch" do
    first_issue = create(:issue, project:)
    second_issue = create(:issue, project:)
    feature = create(:feature_intent, project:, title: "Export reliability", brief: "Exports remain complete.",
      approved_design_revision: "j" * 40)
    create(:feature_intent_issue, feature_intent: feature, issue: first_issue)
    create(:feature_intent_issue, feature_intent: feature, issue: second_issue)
    first_entry = entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue: first_issue)
    second_entry = entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue: second_issue)

    Inbox::GoalContext.preload(entries: [ first_entry, second_entry ])

    [ first_entry, second_entry ].each do |inbox_entry|
      brief = described_class.call(entry: inbox_entry)

      expect(brief.to_h).to include(
        goal: "Exports remain complete.",
        goal_source: "Approved feature intent: Export reliability",
        goal_revision: "j" * 40
      )
      expect(brief.linked_goal_intents).to eq([
        { goal: "Exports remain complete.", source: "Approved feature intent: Export reliability", revision: "j" * 40 }
      ])
    end
  end

  # @spec OPERATOR-INBOX-027
  it "does not treat an unreleased feature record as agreed intent" do
    issue = create(:issue, project:)
    feature = create(:feature_intent, :approved_waiting_for_merge, project:, approved_design_revision: "c" * 40)
    create(:feature_intent_issue, feature_intent: feature, issue:)

    brief = described_class.call(entry: entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue:))

    expect(brief.to_h).to include(
      goal: "No approved intent is available for this work item.",
      goal_source: "Feature intent is not approved"
    )
  end

  # An issue may intentionally serve several designs (the link's issue index is
  # not unique), so no approval supersedes another by recency.
  # @spec OPERATOR-INBOX-027
  it "preserves every linked approved intent when one issue serves two released designs" do
    issue = create(:issue, project:)
    first_design = create(:feature_intent, project:, title: "Exports reliability", brief: "Exports complete without duplicate rows.",
      approved_design_revision: "f" * 40, approved_revision_recorded_at: 3.days.ago)
    second_design = create(:feature_intent, project:, title: "Export performance", brief: "Exports finish in under a second.",
      approved_design_revision: "g" * 40, approved_revision_recorded_at: 1.day.ago)
    create(:feature_intent_issue, feature_intent: first_design, issue:)
    create(:feature_intent_issue, feature_intent: second_design, issue:)

    brief = described_class.call(entry: entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue:))

    expect(brief.to_h).to include(
      goal: "This work item serves more than one approved feature intent.",
      goal_source: "Several approved feature intents are linked to this work item",
      repository_context: project.full_name
    )
    expect(brief.goal_revision).to be_nil
    expect(brief.linked_goal_intents).to contain_exactly(
      { goal: "Exports complete without duplicate rows.", source: "Approved feature intent: Exports reliability", revision: "f" * 40 },
      { goal: "Exports finish in under a second.", source: "Approved feature intent: Export performance", revision: "g" * 40 }
    )
  end

  # @spec OPERATOR-INBOX-027
  it "preserves every linked approved intent through the batched goal-context lookup" do
    issue = create(:issue, project:)
    first_design = create(:feature_intent, project:, title: "Exports reliability", brief: "Exports complete without duplicate rows.",
      approved_design_revision: "h" * 40, approved_revision_recorded_at: 3.days.ago)
    second_design = create(:feature_intent, project:, title: "Export performance", brief: "Exports finish in under a second.",
      approved_design_revision: "i" * 40, approved_revision_recorded_at: 1.day.ago)
    create(:feature_intent_issue, feature_intent: first_design, issue:)
    create(:feature_intent_issue, feature_intent: second_design, issue:)
    inbox_entry = entry(Inbox::Queue::MANUAL_REVIEW_KIND, issue:)

    Inbox::GoalContext.preload(entries: [ inbox_entry ])
    brief = described_class.call(entry: inbox_entry)

    expect(brief.linked_goal_intents).to contain_exactly(
      { goal: "Exports complete without duplicate rows.", source: "Approved feature intent: Exports reliability", revision: "h" * 40 },
      { goal: "Exports finish in under a second.", source: "Approved feature intent: Export performance", revision: "i" * 40 }
    )
  end

  # @spec OPERATOR-INBOX-027
  it "discloses unavailable agreed intent instead of relabeling the queue title as a goal" do
    brief = described_class.call(entry: entry(Inbox::Queue::MANUAL_REVIEW_KIND,
      title_text: "Resolve an unrelated queue item"))

    expect(brief.to_h).to include(
      goal: "No approved intent is available for this work item.",
      goal_source: "Intent unavailable",
      repository_context: project.full_name
    )
    expect(brief.to_h).not_to have_key(:goal_revision)
    expect(brief.linked_goal_intents).to be_empty
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
  it "builds a partial-closeout list summary without resolving its recommendation" do
    prerequisite = create(:issue, project:, github_number: 512, title: "Verify the production result")
    blocked_issue = create(:issue, project:, github_number: 511)
    create(:issue_dependency, issue: blocked_issue, depends_on_issue: prerequisite)
    closeout = entry(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, issue: blocked_issue, tasks: [ "#512" ])
    queries = []
    callback = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] if payload[:sql].include?("issue_dependencies") }

    summary = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.list_summary(entry: closeout)
    end

    expect(summary).to eq("Choose how to finish the remaining acceptance criteria. — This issue still has remaining acceptance work.")
    expect(queries).to be_empty
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
