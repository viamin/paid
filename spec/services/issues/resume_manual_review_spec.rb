# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ResumeManualReview do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }

  def parked_issue(**attributes)
    create(:issue, project:, paid_state: "manual_review", **attributes)
  end

  def resume(issue, goal: nil, actor: user)
    described_class.call(issue:, actor:, goal:)
  end

  describe "enhancement cause" do
    let(:issue) { parked_issue(manual_review_reason: "Paid reached the configured limit of 3 enhancement re-evaluation rounds.") }

    # @spec MANUAL-REVIEW-RECOVERY-004
    it "queues an enhancement run and lifts the hold" do
      result = resume(issue)

      expect(result).to be_success
      expect(result.agent_run.goal).to eq("enhance_issue")
      expect(result.agent_run.trigger_type).to eq("manual")
      expect(result.agent_run.initiating_user).to eq(user)
      expect(issue.reload.paid_state).to eq("in_progress")
      expect(issue.manual_review_started_at).to be_nil
    end

    # @spec MANUAL-REVIEW-RECOVERY-004
    it "enqueues the run queue" do
      expect { resume(issue) }.to have_enqueued_job(ProcessRunQueueJob)
    end

    # @spec MANUAL-REVIEW-RECOVERY-004
    it "keeps the preserved clarifying questions available for the answer form" do
      issue.update!(needs_input_questions: [ "Which events should be recorded?" ])

      expect(Inbox::ManualReviewCause.call(issue:).code).to eq("enhancement")
    end
  end

  describe "dependency cause" do
    let(:issue) do
      parked_issue(manual_review_reason: "Paid's agent run completed and opened a pull request, but this issue remains " \
        "open and is #{Issue::DEPENDENCY_BLOCKED_REASON_MARKER}: #4321. This issue stays pending until the dependency " \
        "resolves or a human intervenes.")
    end

    # @spec MANUAL-REVIEW-RECOVERY-003
    it "refuses to queue an enhancement run and keeps the hold" do
      expect { resume(issue) }.not_to change(AgentRun, :count)

      result = resume(issue)

      expect(result).not_to be_success
      expect(result.code).to eq(:dependency_wait)
      expect(result.message).to include("#4321")
      expect(issue.reload.paid_state).to eq("manual_review")
    end
  end

  describe "reopen review cause" do
    let(:issue) { parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON) }

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "refuses to resume before the intent validation is recorded" do
      expect { resume(issue) }.not_to change(AgentRun, :count)

      result = resume(issue)

      expect(result).not_to be_success
      expect(result.code).to eq(:intent_validation_required)
      expect(issue.reload.paid_state).to eq("manual_review")
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "queues the supported continuation after the validation is recorded" do
      issue.update!(reopen_review_decision: "intent_valid", reopen_review_decided_at: Time.current)

      result = resume(issue, goal: "create_pr")

      expect(result).to be_success
      expect(result.agent_run.goal).to eq("create_pr")
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "refuses a continuation when the original intent no longer applies" do
      issue.update!(reopen_review_decision: "intent_superseded", reopen_review_decided_at: Time.current)

      result = resume(issue)

      expect(result).not_to be_success
      expect(issue.reload.paid_state).to eq("manual_review")
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "refuses a continuation when the scope changed after the validation" do
      issue.update!(
        reopen_review_decision: "intent_valid",
        reopen_review_decided_at: Time.current,
        reopen_review_revision: Issue.reopen_review_revision_for(title: issue.title, body: issue.body)
      )
      issue.update_columns(body: "A different scope")

      result = resume(issue, goal: "create_pr")

      expect(result).not_to be_success
      expect(result.code).to eq(:intent_validation_required)
      expect(issue.reload.paid_state).to eq("manual_review")
    end

    # @spec MANUAL-REVIEW-RECOVERY-003
    it "does not let a recorded validation waive an unresolved dependency" do
      dependency = create(:issue, project:, github_number: 4321)
      create(:issue_dependency, issue:, depends_on_issue: dependency)
      issue.update!(
        reopen_review_decision: "intent_valid",
        reopen_review_decided_at: Time.current,
        manual_review_reason: "Paid's agent run completed and opened a pull request, but this issue remains open and is " \
          "#{Issue::DEPENDENCY_BLOCKED_REASON_MARKER}: #4321. This issue stays pending until the dependency resolves or a " \
          "human intervenes."
      )

      result = resume(issue, goal: "create_pr")

      expect(result).not_to be_success
      expect(result.code).to eq(:dependency_wait)
      expect(issue.reload.paid_state).to eq("manual_review")
    end
  end

  describe "scanner recurrence cause" do
    let(:issue) do
      parked_issue(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
        manual_review_reason: "Code-scanning alert #1838 has a scanner-confirmed recurrence.")
    end

    before { create(:code_scanning_remediation_attempt, issue:, status: "verification_failed") }

    # @spec MANUAL-REVIEW-RECOVERY-004
    it "routes to the remediation run instead of an enhancement retry" do
      result = resume(issue)

      expect(result).to be_success
      expect(result.agent_run.goal).to eq("create_pr")
    end
  end

  describe "unknown cause" do
    let(:issue) { parked_issue(manual_review_reason: "CI repair required.") }

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "still offers a recovery while the cause stays visible" do
      result = resume(issue)

      expect(result).to be_success
      expect(result.agent_run.goal).to eq("enhance_issue")
    end
  end

  describe "queued and running work" do
    let(:issue) { parked_issue(manual_review_reason: "Round limit reached.") }

    # @spec MANUAL-REVIEW-RECOVERY-005
    it "reuses a queued run with the same goal instead of creating a second one" do
      queued = create(:agent_run, project:, issue:, goal: "enhance_issue", status: "queued")

      result = resume(issue)

      expect(result).to be_success
      expect(result.agent_run).to eq(queued)
      expect(result.message).to include("##{queued.id}")
      expect(issue.reload.paid_state).to eq("in_progress")
      expect(AgentRun.where(issue:).count).to eq(1)
    end

    # @spec MANUAL-REVIEW-RECOVERY-005
    it "refuses to clear the hold while an incompatible run is queued" do
      queued = create(:agent_run, project:, issue:, goal: "create_pr", status: "queued")

      expect { resume(issue) }.not_to change(AgentRun, :count)

      result = resume(issue)

      expect(result).not_to be_success
      expect(result.code).to eq(:conflicting_run)
      expect(result.message).to include("##{queued.id}")
      expect(result.message).to include("create_pr")
      expect(issue.reload.paid_state).to eq("manual_review")
    end

    # @spec MANUAL-REVIEW-RECOVERY-005
    it "refuses to clear the hold while a running automatic implementation continues" do
      create(:agent_run, project:, issue:, goal: "create_pr", status: "running", trigger_type: "automatic")

      result = resume(issue)

      expect(result).not_to be_success
      expect(result.code).to eq(:conflicting_run)
      expect(issue.reload.paid_state).to eq("manual_review")
    end
  end

  describe "refusals" do
    let(:issue) { parked_issue(manual_review_reason: "Round limit reached.") }

    # @spec MANUAL-REVIEW-RECOVERY-007
    it "refuses an issue that already left manual review" do
      issue.update!(paid_state: "in_progress")

      result = resume(issue)

      expect(result).not_to be_success
      expect(result.code).to eq(:not_in_manual_review)
      expect(result.message).to eq("This issue is no longer waiting for manual review.")
    end

    # @spec MANUAL-REVIEW-RECOVERY-007
    it "refuses an actor from another account" do
      outsider = create(:user, account: create(:account))

      expect { resume(issue, actor: outsider) }.not_to change(AgentRun, :count)

      result = resume(issue, actor: outsider)

      expect(result).not_to be_success
      expect(result.code).to eq(:not_authorized)
      expect(issue.reload.paid_state).to eq("manual_review")
    end

    # @spec MANUAL-REVIEW-RECOVERY-005
    it "keeps the issue parked when the budget blocks the run" do
      create(:cost_budget, :hard_stop, :daily, project: project,
        limit_cents: 100, current_usage_cents: 200, period_started_at: Time.current.beginning_of_day)

      expect { resume(issue) }.not_to change(AgentRun, :count)

      result = resume(issue)

      expect(result).not_to be_success
      expect(result.code).to eq(:budget_exhausted)
      expect(result.message).to include("budget has been reached")
      expect(issue.reload.paid_state).to eq("manual_review")
    end

    # @spec MANUAL-REVIEW-RECOVERY-004
    it "refuses a goal the cause does not support" do
      result = resume(issue, goal: "create_pr")

      expect(result).not_to be_success
      expect(result.code).to eq(:unsupported_goal)
      expect(issue.reload.paid_state).to eq("manual_review")
    end
  end
end
