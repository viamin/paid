# frozen_string_literal: true

module Inbox
  # Classifies a manual-review stop from durable producers instead of human prose.
  # @spec OPERATOR-INBOX-002D @spec ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Cause = Data.define(:key, :title, :explanation, :action, :action_label, :details)

    ACTIONS = {
      enhancement: [ "retry_analysis", "Start enhancement run" ],
      reopen_review: [ "resume_implementation", "Validate intent and resume implementation" ],
      technical_failure: [ "resume_implementation", "Resume implementation" ]
    }.freeze

    def initialize(issue:)
      @issue = issue
    end

    def cause
      return reopen_cause if issue.reopen_review_pending?
      return dependency_cause unless issue.ready_to_work?
      return build(:scanner_recurrence, "Scanner recurrence", "Collect new scanner evidence; an enhancement retry cannot resolve this finding.") if scanner_blockers.any?
      return build(:enhancement, "Enhancement analysis", "Retry issue analysis while preserving any answerable questions.") if enhancement_provenance?
      return build(:technical_failure, "Implementation recovery", "Resume implementation after a technical, parser, or transport failure.") if latest_run

      build(:unknown, "Unknown manual-review cause", "Paid retained the unclassified stop. Review its provenance before choosing a recovery.")
    end

    def active_runs
      issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(:created_at, :id)
    end

    private

    attr_reader :issue

    def build(key, title, explanation, details: [])
      action, action_label = ACTIONS[key]
      Cause.new(key:, title:, explanation:, action:, action_label:, details:)
    end

    def dependency_cause
      details = issue.blocking_issues.map { |blocked| "#{blocked.project.full_name}##{blocked.github_number}" }
      details += issue.blocking_external_dependencies.map(&:external_ref)
      details += issue.blocking_deployment_dependencies.map { |dependency| "#{dependency.depends_on_issue.github_url} (deployment pending)" }
      build(:dependency, "Unresolved dependency", "Resolve the listed prerequisite; acknowledging this hold does not waive it.", details: details.compact)
    end

    def reopen_cause
      details = []
      details << "Reopen reason: #{issue.reopen_reason}" if issue.reopen_reason.present?
      completed = issue.agent_runs.where(status: "completed").order(created_at: :desc, id: :desc).first
      details << "Prior closure work: #{completed.pull_request_url || "run ##{completed.id}"}" if completed
      build(:reopen_review, "Reopen validation", "Record a revision-bound intent validation before work continues.", details: details)
    end

    def scanner_blockers
      @scanner_blockers ||= Issues::CloseoutStatus.scanner_verification_blockers(issue)
    end

    def enhancement_provenance?
      issue.needs_input_questions.present? || latest_run&.enhance_issue_goal?
    end

    def latest_run
      @latest_run ||= issue.agent_runs.order(created_at: :desc, id: :desc).first
    end
  end
end
