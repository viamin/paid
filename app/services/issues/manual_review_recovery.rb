# frozen_string_literal: true

module Issues
  # Routes a manual-review hold from durable state, rather than treating the
  # shared paid_state as permission to restart enhancement. The result is used
  # by every caller so a web retry cannot bypass the same active-work and
  # revision checks an API or chat caller receives.
  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002L
  class ManualReviewRecovery
    Result = Struct.new(:code, :message, :agent_run, :cause, :blockers, keyword_init: true) do
      def success? = code.nil?
    end

    ENHANCEMENT_STOP_REASONS = [
      "Structured output was invalid.",
      "Paid could not validate the enhancement agent's structured output."
    ].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, reason: nil, review_revision: nil, runner_resolver: nil)
      @issue = issue
      @actor = actor
      @reason = reason.to_s.strip
      @review_revision = review_revision
      @runner_resolver = runner_resolver
    end

    def call
      issue.with_lock { recover }
    end

    def self.cause_for(issue)
      return :reopen_review if issue.reopen_review_pending?
      return :dependency if issue.blocking_issues.exists? || issue.blocking_deployment_dependencies.exists? || issue.blocking_external_dependencies.exists?
      return :scanner_recurrence if issue.code_scanning_remediation_attempts.latest_per_issue.where(status: "verification_failed").exists?
      return :enhancement if issue.needs_input_questions.present? || issue.agent_runs.where(goal: "enhance_issue").exists?
      return :enhancement if ENHANCEMENT_STOP_REASONS.include?(issue.manual_review_reason)
      return :enhancement if issue.manual_review_reason.to_s.start_with?("Structured output")
      return :enhancement if issue.manual_review_reason.to_s.start_with?("Paid reached the configured limit", "Round limit reached")

      :unknown
    end

    private

    attr_reader :actor, :issue, :reason, :review_revision, :runner_resolver

    def recover
      return failure(:not_manual_review, "This issue is no longer waiting for manual review.") unless issue.paid_state == "manual_review"

      cause = self.class.cause_for(issue)
      return dependency_result(cause) if cause == :dependency
      return failure(:unknown_cause, "Paid cannot determine why this issue is in manual review; no recovery was queued.", cause:) if cause == :unknown
      return reopen_result(cause) if cause == :reopen_review

      queue_or_reuse(cause, goal_for(cause))
    end

    def dependency_result(cause)
      blockers = issue.blocking_issues.to_a
      return failure(:dependency_pending, "This issue is waiting for deployment or an external dependency.", cause:, blockers:) if blockers.empty?

      failure(:dependency_pending, "This issue is waiting for #{blockers.map { |blocker| "##{blocker.github_number}" }.join(', ')}.", cause:, blockers:)
    end

    def reopen_result(cause)
      return failure(:invalid_reason, "A reopen-review validation reason is required.", cause:) if reason.blank?
      return failure(:stale_revision, "This reopen review changed before your decision could be recorded.", cause:) unless current_revision?

      result = queue_or_reuse(cause, "create_pr")
      return result unless result.success?

      record_reopen_decision unless result.agent_run.persisted? && result.agent_run.created_at < 1.second.ago
      result
    end

    def current_revision?
      review_revision.present? && review_revision.to_time == issue.manual_review_started_at&.to_time
    end

    def queue_or_reuse(cause, goal)
      active = issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
      return active_result(active, goal, cause) if active
      return failure(:budget_exhausted, "The project's AI budget has been reached.", cause:) unless CostBudgets::Check.call(issue.project)[:allowed]

      runner_id, agent_type = resolve_runner(goal)
      return failure(:no_runnable_runner, "No runnable runner could be resolved for this project.", cause:) unless runner_id.present?

      run = AgentRun.create!(project: issue.project, issue:, initiating_user: actor, runner_id:, agent_type:, goal:,
        trigger_type: "manual", review_depth_snapshot: issue.project.effective_review_depth, status: "queued")
      issue.update!(paid_state: "in_progress")
      ProcessRunQueueJob.perform_later
      Result.new(agent_run: run, cause:)
    end

    def active_result(active, goal, cause)
      return Result.new(agent_run: active, cause:) if active.goal == goal

      failure(:incompatible_active_run, "Run ##{active.id} (#{active.goal}) is already #{active.status}; reconcile it before starting #{goal}.", cause:)
    end

    def record_reopen_decision
      Audit::RecordEvent.call(action: "issue.reopen_review_resolved", actor:, subject: issue, metadata: {
        "reason" => reason,
        "manual_review_started_at" => review_revision.utc.iso8601,
        "continuation" => "implementation"
      })
    end

    def goal_for(cause)
      cause == :scanner_recurrence ? "create_pr" : "enhance_issue"
    end

    def resolve_runner(goal)
      return AgentRuns::RunnerResolver.call(project: issue.project, goal:) unless runner_resolver

      runner = runner_resolver.call(goal)
      [ runner&.id, runner && Runner.agent_type_for(runner.runner_key) ]
    end

    def failure(code, message, cause:, blockers: []) = Result.new(code:, message:, cause:, blockers:)
  end
end
