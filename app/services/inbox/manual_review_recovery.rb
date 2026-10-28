# frozen_string_literal: true

module Inbox
  # Projects persisted manual-review provenance into operator-facing causes and
  # supported recovery actions. It never interprets free-form reason text.
  # @spec OPERATOR-INBOX-002D @spec ISSUE-REOPEN-REVIEW-005
  class ManualReviewRecovery
    Cause = Data.define(:type, :label, :explanation, :action, :evidence, :links)
    Snapshot = Data.define(:causes, :active_runs, :required_revision) do
      def primary = causes.first

      def action
        primary.action if causes.one?
      end

      def unknown? = causes.any? { |cause| cause.type == :unknown }
    end

    def self.call(issue, inputs: nil) = new(issue, inputs:).call

    def initialize(issue, inputs: nil)
      @issue = issue
      @inputs = inputs
    end

    def call
      Snapshot.new(causes: causes, active_runs: active_runs, required_revision: revision)
    end

    private

    attr_reader :issue, :inputs

    def causes
      @causes ||= begin
        holds = [ reopen_cause, dependency_cause, scanner_cause ].compact
        holds.presence || [ enhancement_cause, recovery_cause ].compact.presence || [ unknown_cause ]
      end
    end

    def reopen_cause
      return unless issue.reopen_review_pending?

      Cause.new(type: :reopen_review, label: "Reopen intent validation",
        explanation: "Record a revision-bound decision before continuing this reopened issue.",
        action: :record_reopen_decision, evidence: reopen_evidence, links: [])
    end

    def dependency_cause
      links = dependency_links
      return if links.empty?

      Cause.new(type: :dependency, label: "Unresolved dependency",
        explanation: "Resolve the owning dependency; an acknowledgement cannot waive this hold.",
        action: nil, evidence: { dependency_count: links.size }, links:)
    end

    def scanner_cause
      blockers = Issues::CloseoutStatus.scanner_verification_blockers(issue, inputs:)
      return if blockers.empty?

      blocker = blockers.first
      Cause.new(type: :scanner_recurrence, label: "Scanner recurrence",
        explanation: blocker.recovery, action: :resume_implementation,
        evidence: blocker.evidence, links: [])
    end

    def enhancement_cause
      return unless issue.needs_input_questions.present? || latest_run&.goal == "enhance_issue" || issue.enhance_issue_rounds.positive?

      Cause.new(type: :enhancement, label: "Enhancement analysis",
        explanation: "Answer preserved questions or retry issue analysis.", action: :retry_analysis,
        evidence: run_evidence(latest_run), links: [])
    end

    def recovery_cause
      run = latest_run
      return unless run&.status.in?(AgentRun::TERMINAL_FAILURE_STATUSES + [ "no_output" ])
      return if run.goal == "enhance_issue"

      Cause.new(type: :technical_recovery, label: "Technical recovery",
        explanation: "Retry the originating #{run.goal.humanize.downcase} work without re-running enhancement.",
        action: run.goal == "create_pr" ? :resume_implementation : :retry_originating_work,
        evidence: run_evidence(run), links: [])
    end

    def unknown_cause
      Cause.new(type: :unknown, label: "Unknown manual-review cause",
        explanation: "No supported recovery provenance is recorded. Investigate before clearing this hold.",
        action: nil, evidence: {}, links: [])
    end

    def dependency_links
      return dependency_labels.map { |label| dependency_link(label) } if inputs

      issue.blocking_issues.map { |dependency| { label: "Issue ##{dependency.github_number}", url: dependency.github_url } } +
        issue.blocking_deployment_dependencies.includes(:depends_on_issue).map do |dependency|
          target = dependency.depends_on_issue
          { label: "PR ##{target.github_number} deployment", url: target.github_url }
        end + issue.blocking_external_dependencies.map do |dependency|
          { label: dependency.external_ref,
            url: "https://github.com/#{dependency.depends_on_owner}/#{dependency.depends_on_repo}/issues/#{dependency.depends_on_number}" }
        end
    end

    def dependency_labels
      inputs.prerequisites_by_issue_id.fetch(issue.id, [])
    end

    def dependency_link(label)
      if label.start_with?("#")
        dependency = issue.issue_dependencies.map(&:depends_on_issue).compact.find do |candidate|
          candidate.github_number == label.delete_prefix("#").to_i
        end
        return { label: "Issue #{label}", url: dependency.github_url } if dependency
      end

      owner_repo, number = label.split("#", 2)
      { label:, url: "https://github.com/#{owner_repo}/issues/#{number}" }
    end

    def reopen_evidence
      { prior_closed_at: (issue.closed_at || prior_completion_run&.completed_at)&.iso8601,
        prior_run_id: prior_completion_run&.id, reopened_at: issue.reopened_at&.iso8601,
        reopen_reason: issue.reopen_reason, current_scope: issue.body }
    end

    def run_evidence(run)
      return {} unless run

      { run_id: run.id, goal: run.goal, status: run.status }
    end

    def latest_run
      @latest_run ||= ordered_runs.first
    end

    def prior_completion_run
      @prior_completion_run ||= ordered_runs.select { |run| run.status == "completed" }.max_by { |run| [ run.completed_at || Time.at(0), run.id ] }
    end

    def active_runs
      @active_runs ||= ordered_runs.select { |run| run.status.in?(AgentRun::UNFINISHED_STATUSES) }
        .sort_by { |run| [ run.created_at, run.id ] }.map { |run| run_evidence(run) }
    end

    def ordered_runs
      @ordered_runs ||= if issue.association(:agent_runs).loaded?
        issue.agent_runs.sort_by { |run| [ run.created_at, run.id ] }.reverse
      else
        issue.agent_runs.order(created_at: :desc, id: :desc).to_a
      end
    end

    def revision
      issue.github_updated_at&.iso8601
    end
  end
end
