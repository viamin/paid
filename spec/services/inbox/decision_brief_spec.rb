# frozen_string_literal: true

require "rails_helper"

# @spec INBOX-DECISION-BRIEF-001 INBOX-DECISION-BRIEF-002
# @spec INBOX-DECISION-BRIEF-004 INBOX-DECISION-BRIEF-006
RSpec.describe Inbox::DecisionBrief do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, owner: "acme", repo: "alpha",
      auto_pick_enabled: true, active: true)
  end

  def build_entry(kind, **overrides)
    defaults = {
      id: "#{kind}:1",
      kind: kind,
      project: project,
      issue: nil,
      record: nil,
      waiting_since: 1.hour.ago,
      questions: [],
      tasks: [],
      summary_text: nil,
      title_text: nil,
      action_url: nil,
      guidance: nil,
      closeout_status: nil
    }
    Inbox::Queue::Entry.new(defaults.merge(overrides))
  end

  def count_queries
    queries = []
    ActiveSupport::Notifications.subscribed(->(event) { queries << event.payload[:name] }, "sql.active_record") do
      yield
    end
    queries
  end

  # Minimal record doubles per kind, mirroring the shapes the queue builders
  # attach (see spec/views/dashboard/inbox_detail_navigation_intent_spec.rb).
  def entry_for(kind)
    case kind
    when Inbox::Queue::CLARIFYING_QUESTIONS_KIND
      issue = create(:issue, :needs_input, project: project, title: "Ship the export")
      build_entry(kind, record: issue, issue: issue, questions: [ "Which format should the export use?" ])
    when Inbox::Queue::PLAN_REVIEW_KIND
      issue = create(:issue, project: project, title: "Plan the migration")
      build_entry(kind, record: nil, issue: issue, tasks: [ { "title" => "Add column" } ])
    when Inbox::Queue::MERGE_APPROVAL_KIND
      issue = create(:issue, :pull_request, project: project, title: "Add the exporter")
      build_entry(kind, record: issue, issue: issue,
        guidance: { heading: "Review on GitHub", instruction: "Approve the current revision on GitHub.",
          stale_approval: false, blockers: [] })
    when Inbox::Queue::ACTION_REQUIRED_KIND
      issue = create(:issue, project: project, title: "Blocked rollout")
      notification = create(:notification, :error, account: account, subject: issue, blocking: true,
        title: "Re-grant the token", description: "The stored token expired.",
        action_url: "/projects/#{project.id}/edit",
        metadata: { "recommended_action" => "Rotate the token in project settings." })
      build_entry(kind, record: notification, issue: issue, summary_text: "The stored token expired.",
        title_text: "Re-grant the token", action_url: "/projects/#{project.id}/edit")
    when Inbox::Queue::ESCALATED_PR_KIND
      issue = create(:issue, :pull_request, project: project, title: "Flaky delivery")
      blocked = Struct.new(:reason, :pull_request, :operator_paused, :counters, :last_progress_at, keyword_init: true)
          .new(reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK, pull_request: issue,
            operator_paused: false, counters: [], last_progress_at: 1.day.ago)
      build_entry(kind, record: blocked, issue: issue)
    when Inbox::Queue::MANUAL_REVIEW_KIND
      issue = create(:issue, project: project, title: "Reopened bug", paid_state: "manual_review")
      build_entry(kind, record: issue, issue: issue, questions: [ "Is the remaining scope still wanted?" ],
        summary_text: "Stopped for manual review.")
    when Inbox::Queue::INTENT_CONFORMANCE_KIND
      issue = create(:issue, :pull_request, project: project, title: "Refactor the parser")
      snapshot = Struct.new(:summary, :verdict, :latest_decision, keyword_init: true)
        .new(summary: "The change drifts from the approved design.", verdict: nil, latest_decision: nil)
      build_entry(kind, record: snapshot, issue: issue)
    when Inbox::Queue::FEATURE_DECISION_KIND
      feature_intent = create(:feature_intent, project: project, title: "Add CSV export",
        brief: "Users can export their data as CSV.")
      build_entry(kind, record: feature_intent, summary_text: "Waiting for approval.",
        title_text: feature_intent.title)
    when Inbox::Queue::RETRY_LIMITED_KIND
      issue = create(:issue, project: project, title: "Retry storm")
      issue.update_columns(runner_retry_abandoned_at: 1.hour.ago, runner_retry_abandonment_count: 3,
        runner_retry_abandon_reason: "Retry cap reached")
      build_entry(kind, record: issue, issue: issue, summary_text: "Retry cap reached")
    when Inbox::Queue::CHANGE_INTENT_DRAFT_KIND
      change_intent = create(:change_intent, :draft, project: project, title: "Prefer sliding window")
      build_entry(kind, record: change_intent, title_text: change_intent.title)
    when Inbox::Queue::PARTIAL_CLOSEOUT_KIND
      issue = create(:issue, project: project, title: "Partial epic", paid_state: "in_progress")
      status = Struct.new(:reason, :outcome, :blockers, :unresolved_prerequisites, :evidence, keyword_init: true)
        .new(reason: "merged partial PR keeps auto-pick off",
          outcome: "Paid recorded merged partial PR #12; paid_state is in_progress.",
          blockers: [], unresolved_prerequisites: [],
          evidence: Struct.new(:merged_prs, :terminal_at, :no_code_required_at, keyword_init: true)
            .new(merged_prs: [ Struct.new(:number).new(12) ], terminal_at: 1.day.ago, no_code_required_at: nil))
      build_entry(kind, record: issue, issue: issue, closeout_status: status,
        summary_text: "merged partial PR keeps auto-pick off")
    when Inbox::Queue::TEST_REVIEW_PENDING_KIND
      issue = create(:issue, :pull_request, project: project, title: "Red-phase tests")
      build_entry(kind, record: issue, issue: issue)
    when Inbox::Queue::PROJECT_SETUP_PENDING_KIND
      build_entry(kind, record: project, tasks: [ "Connect CI." ], title_text: "Set up acme/alpha",
        action_url: "/projects/#{project.id}/edit")
    when Inbox::Queue::TRACEABILITY_GAP_KIND
      finding = Struct.new(:artifact_path, :unverifiable?, :state, :evidence, keyword_init: true)
        .new(artifact_path: "docs/rdrs/RDR-063.md", unverifiable?: false, state: "missing_tree", evidence: [ "No links." ])
      build_entry(kind, record: finding, tasks: [ "No links." ])
    when Inbox::Queue::LAYERED_VERIFICATION_FINDING_KIND
      finding = Struct.new(:decision, keyword_init: true).new(decision: { "question" => "Is the rollback plan tested?" })
      build_entry(kind, record: finding)
    when Inbox::Queue::DEPENDENCY_CYCLE_KIND
      first = create(:issue, project: project, github_state: "open")
      second = create(:issue, project: project, github_state: "open")
      cycle = Struct.new(:path, :downstream_issues, :summary) do
        def umbrella_for(_issue) = nil
      end.new([ first, second ], [], "Cycle detected")
      build_entry(kind, record: cycle, summary_text: "Cycle detected")
    else
      raise ArgumentError, "unhandled kind #{kind}"
    end
  end

  describe "the reusable contract" do
    it "derives a plain-language brief for every inbox kind without leaving the entry's structured state" do
      # @spec INBOX-DECISION-BRIEF-001
      Inbox::Queue::KINDS.each do |kind|
        entry = entry_for(kind)
        brief = described_class.call(entry:)

        expect(brief.decision).to be_present, "#{kind} has no decision copy"
        expect(brief.impact).to be_present, "#{kind} has no impact copy"
        [ brief.goal, brief.changed, brief.decision, brief.impact, brief.recommendation,
          brief.rationale, brief.after_action, brief.question ].compact.each do |text|
          expect(text).not_to match(/[{]|=>|#</), "#{kind} leaks raw structure: #{text}"
          expect(text).not_to match(/\b[0-9a-f]{16,}\b/), "#{kind} leaks hashes: #{text}"
        end
      end
    end

    it "exposes the same field set for every kind" do
      # @spec INBOX-DECISION-BRIEF-001
      brief = described_class.call(entry: entry_for(Inbox::Queue::CLARIFYING_QUESTIONS_KIND))

      expect(brief.to_h.keys).to contain_exactly(:goal, :changed, :decision, :impact, :recommendation,
        :rationale, :after_action, :question, :unknowns, :evidence, :primary_action, :last_decision)
    end

    it "issues no database queries and no remote calls in list mode" do
      # @spec INBOX-DECISION-BRIEF-002
      entry = entry_for(Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      queries = count_queries { described_class.call(entry:) }
      expect(queries.grep(/active_record/i)).to be_empty
    end
  end

  describe "grounded recommendations and disclosures" do
    it "grounds the merge-approval recommendation in the persisted guidance" do
      # @spec INBOX-DECISION-BRIEF-006
      entry = entry_for(Inbox::Queue::MERGE_APPROVAL_KIND)

      brief = described_class.call(entry:)

      expect(brief.recommendation).to eq("Approve the current revision on GitHub.")
      expect(brief.unknowns).to be_empty
    end

    it "discloses a stale approval instead of presenting the recommendation as certain" do
      # @spec INBOX-DECISION-BRIEF-006
      issue = create(:issue, :pull_request, project: project, title: "Add the exporter")
      entry = build_entry(Inbox::Queue::MERGE_APPROVAL_KIND, record: issue, issue: issue,
        guidance: { heading: "Approval is stale for the current revision",
          instruction: "Review and approve the current revision on GitHub.",
          stale_approval: true, blockers: [] })

      brief = described_class.call(entry:)

      expect(brief.recommendation).to be_present
      expect(brief.unknowns.join(" ")).to match(/approval (is stale|predates)/i)
    end

    it "grounds the partial-closeout recommendation in the recorded acceptance assessment" do
      # @spec INBOX-DECISION-BRIEF-006
      issue = create(:issue, project: project, paid_state: "in_progress", title: "Partial epic")
      assessment = Struct.new(:stale?, :next_action, :assessed_at, keyword_init: true)
        .new(stale?: false, next_action: { "explanation" => "Close the accepted issue on GitHub." },
          assessed_at: 1.hour.ago)
      allow(PartialCloseouts::Assessment).to receive(:call).and_return(assessment)
      entry = build_entry(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, record: issue, issue: issue,
        closeout_status: entry_for(Inbox::Queue::PARTIAL_CLOSEOUT_KIND).closeout_status)

      brief = described_class.call(entry:, detail: true)

      expect(brief.recommendation).to eq("Close the accepted issue on GitHub.")
      expect(brief.unknowns).to be_empty
    end

    it "discloses a stale acceptance assessment and asks one focused question instead of recommending" do
      # @spec INBOX-DECISION-BRIEF-004 INBOX-DECISION-BRIEF-006
      issue = create(:issue, project: project, paid_state: "in_progress", title: "Partial epic")
      assessment = Struct.new(:stale?, :next_action, :assessed_at, keyword_init: true)
        .new(stale?: true, next_action: { "explanation" => "Close the accepted issue on GitHub." },
          assessed_at: 2.days.ago)
      allow(PartialCloseouts::Assessment).to receive(:call).and_return(assessment)
      entry = build_entry(Inbox::Queue::PARTIAL_CLOSEOUT_KIND, record: issue, issue: issue,
        closeout_status: entry_for(Inbox::Queue::PARTIAL_CLOSEOUT_KIND).closeout_status)

      brief = described_class.call(entry:, detail: true)

      expect(brief.recommendation).to be_nil
      expect(brief.unknowns.join(" ")).to match(/stale/i)
      expect(brief.question).to be_present
    end

    it "keeps raw closeout slugs out of the default brief copy" do
      # @spec INBOX-DECISION-BRIEF-004
      entry = entry_for(Inbox::Queue::PARTIAL_CLOSEOUT_KIND)

      brief = described_class.call(entry:)

      default_view = [ brief.goal, brief.changed, brief.decision, brief.impact,
        brief.recommendation, brief.question ].compact.join(" ")
      expect(default_view).not_to include("paid_state")
      expect(default_view).not_to include("auto-pick")
      expect(brief.changed).to be_present
    end

    it "separates the clarifying question from the explanation and grounds the goal in the work item" do
      # @spec INBOX-DECISION-BRIEF-004
      entry = entry_for(Inbox::Queue::CLARIFYING_QUESTIONS_KIND)

      brief = described_class.call(entry:, detail: true)

      expect(brief.question).to eq("Which format should the export use?")
      expect(brief.recommendation).to be_nil
      expect(brief.goal).to eq("Ship the export")
      expect(brief.decision).to be_present
      expect(brief.decision).not_to eq(brief.question)
    end
  end

  describe "detail-only enrichment" do
    it "surfaces the last agreed decision from the persisted history timeline" do
      # @spec INBOX-DECISION-BRIEF-001
      issue = create(:issue, :needs_input, project: project, title: "Ship the export")
      create(:inbox_history_event, account: account, project: project,
        subject_key: "issue:#{project.id}:#{issue.github_number}",
        event_key: "test-plan-approved", result: "completed",
        occurred_at: 1.day.ago, metadata: { action: "Plan approved" })
      entry = build_entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, record: issue, issue: issue,
        questions: [ "Which format?" ])

      brief = described_class.call(entry:, detail: true)

      expect(brief.last_decision).to include("Plan approved")
    end

    it "keeps the list-mode brief free of the detail-only history lookup" do
      # @spec INBOX-DECISION-BRIEF-002
      issue = create(:issue, :needs_input, project: project, title: "Ship the export")
      entry = build_entry(Inbox::Queue::CLARIFYING_QUESTIONS_KIND, record: issue, issue: issue,
        questions: [ "Which format?" ])

      brief = described_class.call(entry:)

      expect(brief.last_decision).to be_nil
    end

    it "exposes a navigation primary action for URL-actionable lanes" do
      # @spec INBOX-DECISION-BRIEF-001
      entry = entry_for(Inbox::Queue::ACTION_REQUIRED_KIND)

      brief = described_class.call(entry:, detail: true)

      expect(brief.primary_action.to_h).to include(label: "Open linked action", url: entry.action_url)
    end
  end
end
