# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewCause do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }

  def parked_issue(**attributes)
    create(:issue, project:, paid_state: "manual_review", **attributes)
  end

  def cause_for(issue, questions: [])
    described_class.call(issue:, questions:)
  end

  describe "cause classification" do
    # @spec MANUAL-REVIEW-RECOVERY-001
    it "classifies a reopened issue as a reopen review" do
      issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

      expect(cause_for(issue).code).to eq("reopen_review")
    end

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "classifies a dependency-blocked issue as a dependency wait" do
      issue = parked_issue(
        manual_review_reason: "Paid's agent run completed and opened a pull request, but this issue remains open " \
          "and is #{Issue::DEPENDENCY_BLOCKED_REASON_MARKER}: #4321. This issue stays pending until the dependency " \
          "resolves or a human intervenes."
      )

      expect(cause_for(issue).code).to eq("dependency_wait")
    end

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "classifies an unresolved dependency with no other evidence as a dependency wait" do
      dependency = create(:issue, project:, github_number: 4321)
      issue = parked_issue(manual_review_reason: "Paid stopped working this issue.")
      create(:issue_dependency, issue:, depends_on_issue: dependency)

      expect(cause_for(issue).code).to eq("dependency_wait")
    end

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "classifies a structured-output enhancement failure as an enhancement stop" do
      issue = parked_issue(manual_review_reason: "Paid could not validate the enhancement agent's structured output.")

      expect(cause_for(issue).code).to eq("enhancement")
    end

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "classifies preserved clarifying questions as an enhancement stop" do
      issue = parked_issue(manual_review_reason: "Paid stopped working this issue.",
        needs_input_questions: [ "Which events should be recorded?" ])

      expect(cause_for(issue).code).to eq("enhancement")
    end

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "classifies a scanner-confirmed recurrence as a scanner recurrence" do
      issue = parked_issue(project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
        manual_review_reason: "Code-scanning alert #1838 has a scanner-confirmed recurrence after matching post-merge verification; merge evidence is not proof it is fixed.")
      create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

      expect(cause_for(issue).code).to eq("scanner_recurrence")
    end

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "retains an unclassifiable cause visibly instead of reporting an enhancement stop" do
      issue = parked_issue(manual_review_reason: "CI repair required.")

      result = cause_for(issue)

      expect(result.code).to eq("unknown")
      expect(result).to be_unknown
      expect(result.label).to eq("Unclassified manual review")
    end

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "reports an enhancement stop as an enhancement cause even when a dependency edge exists" do
      dependency = create(:issue, project:, github_number: 99)
      issue = parked_issue(manual_review_reason: "Paid reached the configured limit of 3 enhancement re-evaluation rounds.")
      create(:issue_dependency, issue:, depends_on_issue: dependency)

      expect(cause_for(issue).code).to eq("enhancement")
    end
  end

  describe "holds" do
    # @spec MANUAL-REVIEW-RECOVERY-003
    it "reports the blocking dependency with a link to the blocking work" do
      dependency = create(:issue, project:, github_number: 4321, title: "Ship the API")
      issue = parked_issue(manual_review_reason: "blocked on an unresolved dependency")
      create(:issue_dependency, issue:, depends_on_issue: dependency)

      hold = cause_for(issue).holds.find { |candidate| candidate.code == "dependency_wait" }

      expect(hold.message).to include("#4321")
      expect(hold.links.map { |link| link["label"] }).to include("#4321")
    end

    # @spec MANUAL-REVIEW-RECOVERY-003
    it "reports both the reopen review and the dependency when both are recorded" do
      dependency = create(:issue, project:, github_number: 4321)
      issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
      create(:issue_dependency, issue:, depends_on_issue: dependency)

      expect(cause_for(issue).hold_codes).to include("reopen_review", "dependency_wait")
    end

    # @spec MANUAL-REVIEW-RECOVERY-005
    it "reports a queued run that is already working on the issue" do
      issue = parked_issue(manual_review_reason: "Round limit reached.")
      run = create(:agent_run, project:, issue:, goal: "create_pr", status: "queued")

      hold = cause_for(issue).holds.find { |candidate| candidate.code == "run_in_flight" }

      expect(hold.message).to include("##{run.id}")
      expect(hold.message).to include("create_pr")
    end
  end

  describe "actions" do
    # @spec MANUAL-REVIEW-RECOVERY-002
    it "offers the intent validation for a reopen review that has no decision yet" do
      issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

      result = cause_for(issue)

      expect(result.action_kinds).to eq([ "record_intent_validation" ])
      expect(result.actions.first.semantics).to eq("records_decision")
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "offers the supported continuations after a reopen review is validated" do
      issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
        reopen_review_decision: "intent_valid", reopen_review_decided_at: Time.current)

      result = cause_for(issue)

      expect(result.action_kinds).to eq([ "retry_analysis", "resume_implementation" ])
      expect(result.actions.map(&:goal)).to eq([ "enhance_issue", "create_pr" ])
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "offers no continuation when the original intent no longer applies" do
      issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
        reopen_review_decision: "intent_superseded", reopen_review_decided_at: Time.current)

      expect(cause_for(issue).actions).to be_empty
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "asks for a fresh validation when the scope changed after the decision" do
      issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
        title: "Scope", body: "Body",
        reopen_review_decision: "intent_valid", reopen_review_decided_at: Time.current,
        reopen_review_revision: Issue.reopen_review_revision_for(title: "Scope", body: "Body"))
      issue.update_columns(body: "A different scope")

      expect(cause_for(issue).action_kinds).to eq([ "record_intent_validation" ])
    end

    # @spec MANUAL-REVIEW-RECOVERY-003
    it "does not offer an enhancement retry for a dependency wait" do
      dependency = create(:issue, project:, github_number: 4321)
      issue = parked_issue(manual_review_reason: "blocked on an unresolved dependency")
      create(:issue_dependency, issue:, depends_on_issue: dependency)

      result = cause_for(issue)

      expect(result.action_kinds).to eq([ "resolve_dependency" ])
      expect(result.actions.first.semantics).to eq("collects_evidence")
    end

    # @spec MANUAL-REVIEW-RECOVERY-004
    it "offers the enhancement retry for an enhancement stop" do
      issue = parked_issue(manual_review_reason: "Paid reached the configured limit of 3 enhancement re-evaluation rounds.")

      result = cause_for(issue)

      expect(result.action_kinds).to eq([ "retry_analysis" ])
      expect(result.actions.first.goal).to eq("enhance_issue")
      expect(result.actions.first.semantics).to eq("retries_analysis")
    end

    # @spec MANUAL-REVIEW-RECOVERY-004
    it "routes a scanner-confirmed recurrence to the remediation action" do
      issue = parked_issue(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
        manual_review_reason: "Code-scanning alert #1838 has a scanner-confirmed recurrence.")
      create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

      result = cause_for(issue)

      expect(result.action_kinds).to eq([ "resume_implementation" ])
      expect(result.actions.first.goal).to eq("create_pr")
      expect(result.actions.first.semantics).to eq("resumes_implementation")
    end

    # @spec MANUAL-REVIEW-RECOVERY-001
    it "keeps an unknown cause visible while still offering a recovery" do
      issue = parked_issue(manual_review_reason: "CI repair required.")

      result = cause_for(issue)

      expect(result).to be_unknown
      expect(result.action_kinds).to eq([ "retry_analysis" ])
    end
  end

  describe "reopen review scope" do
    # @spec MANUAL-REVIEW-RECOVERY-002
    it "shows the original closure and the remaining scope" do
      issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
        title: "Collect the live validation artifacts",
        body: "Record the stdout, stderr and exit code of the analyzer.",
        closed_at: 2.days.ago)

      scope = cause_for(issue).scope

      expect(scope.closed_at).to be_present
      expect(scope.closure).to include("closed on GitHub")
      expect(scope.remaining).to include("Record the stdout, stderr and exit code")
    end

    # @spec MANUAL-REVIEW-RECOVERY-002
    it "has no scope for a cause that is not a reopen review" do
      issue = parked_issue(manual_review_reason: "Round limit reached.")

      expect(cause_for(issue).scope).to be_nil
    end
  end

  describe "revision" do
    # @spec MANUAL-REVIEW-RECOVERY-002
    it "binds the revision to the issue scope" do
      issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON, title: "Scope", body: "Body")

      expect(cause_for(issue).revision).to eq(
        Issue.reopen_review_revision_for(title: "Scope", body: "Body")
      )
    end
  end
end
