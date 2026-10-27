# frozen_string_literal: true

module Issues
  # Applies one cause-specific operator recovery to a parked issue. All
  # interactive surfaces delegate here so authorization, active-run inspection,
  # and idempotency do not drift by entry point.
  #
  # @spec MANUAL-REVIEW-RECOVERY-002 @spec MANUAL-REVIEW-RECOVERY-003
  # @spec MANUAL-REVIEW-RECOVERY-004 @spec MANUAL-REVIEW-RECOVERY-006
  # @spec MANUAL-REVIEW-RECOVERY-007 @spec MANUAL-REVIEW-RECOVERY-008
  class ManualReviewRecovery
    NoRunnableRunner = Class.new(StandardError)
    Result = Struct.new(:code, :message, :agent_run, :decision, keyword_init: true) do
      def success? = code.nil?
    end

    ACTIONS = %w[
      record_intent_validation
      retry_enhancement
      reevaluate_dependency
      authorize_scanner_remediation
      request_continuation
    ].freeze

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, action:, reason: nil, decision: nil)
      @issue = issue
      @actor = actor
      @action = action.to_s
      @reason = reason.to_s.strip
      @decision = decision.to_s
    end

    def call
      return failure(:invalid_action, "Choose a supported manual-review action.") unless ACTIONS.include?(action)

      issue.with_lock do
        issue.reload
        return failure(:not_parked, "This issue is no longer waiting for manual review.") unless issue.paid_state == "manual_review"

        recover(classification)
      end
    end

    private

    attr_reader :action, :actor, :decision, :issue, :reason

    def classification = @classification ||= ManualReviewCause.call(issue)

    def recover(classification)
      return dependency_wait(classification) if action == "reevaluate_dependency"
      return validation(classification) if action == "record_intent_validation"
      return continuation(classification) if action == "request_continuation"

      resume(classification)
    end

    def validation(classification)
      return wrong_action(classification) unless classification.reopen_review?
      return failure(:invalid_decision, "Choose whether the current issue intent remains valid.") unless valid_intent_decision?
      return failure(:invalid_reason, "A validation reason is required.") if reason.blank?

      saved_decision = record_validation
      return active_run_result if active_run
      return dependency_wait(classification) if classification.dependency_wait?

      issue.update!(paid_state: "new")
      Result.new(code: nil, message: "Intent validation recorded. The issue is ready for normal admission.", decision: saved_decision)
    end

    def dependency_wait(classification)
      return wrong_action(classification) unless classification.dependency_wait?
      return failure(:dependency_unresolved, dependency_message) unless ManualReviewCause.dependencies_for(issue).empty?
      return active_run_result if active_run

      issue.update!(paid_state: "new")
      Result.new(code: nil, message: "Dependencies are resolved. The issue is ready for normal admission.")
    end

    def continuation(classification)
      return wrong_action(classification) unless classification.partial_closeout?
      return active_run_result if active_run

      held_attributes = issue.attributes.slice("paid_state", "manual_review_reason", "manual_review_cause")
      issue.update!(paid_state: "new")
      result = RequestContinuation.call(issue:, actor:, reason: reason)
      unless result.success?
        issue.update!(held_attributes)
        return Result.new(code: result.code, message: result.message)
      end

      Result.new(code: nil, message: "Continuation queued.", agent_run: result.agent_run)
    end

    def resume(classification)
      required_cause, goal = action == "authorize_scanner_remediation" ?
        [ ManualReviewCause::SCANNER_RECURRENCE, "create_pr" ] :
        [ nil, "enhance_issue" ]
      return wrong_action(classification) if required_cause && !classification.include?(required_cause)
      return wrong_action(classification) if action == "retry_enhancement" && !retryable?(classification)
      return active_run_result if active_run

      budget = CostBudgets::Check.call(issue.project)
      return failure(:budget_exhausted, "The project's AI budget has been reached (#{budget[:reason]}).") unless budget[:allowed]

      run = create_run(goal)
      issue.update!(paid_state: "in_progress")
      ProcessRunQueueJob.perform_later
      Result.new(code: nil, message: "#{goal == 'enhance_issue' ? 'Enhancement analysis' : 'Remediation'} queued.", agent_run: run)
    rescue NoRunnableRunner => e
      failure(:no_runnable_runner, e.message)
    rescue ActiveRecord::RecordNotUnique
      active_run_result || failure(:concurrent_recovery, "Another recovery is already being queued for this issue.")
    end

    def retryable?(classification)
      classification.enhancement? || classification.unknown?
    end

    def active_run
      @active_run ||= issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).order(created_at: :desc, id: :desc).first
    end

    def active_run_result
      return unless active_run

      if active_run.goal == requested_goal
        Result.new(code: nil, message: "Existing #{active_run.status} run ##{active_run.id} already covers this recovery.", agent_run: active_run)
      else
        failure(:conflicting_run, "Run ##{active_run.id} (#{active_run.goal}) is already #{active_run.status}; reconcile it before this recovery.")
      end
    end

    def requested_goal
      case action
      when "authorize_scanner_remediation", "request_continuation" then "create_pr"
      else "enhance_issue"
      end
    end

    def create_run(goal)
      runner = runner_for(goal)
      raise NoRunnableRunner, "No runnable runner could be resolved for this project." unless runner

      AgentRun.create!(
        project: issue.project,
        issue: issue,
        initiating_user: actor,
        runner: runner,
        agent_type: Runner.agent_type_for(runner.runner_key),
        goal: goal,
        trigger_type: "manual",
        review_depth_snapshot: issue.project.effective_review_depth,
        status: "queued"
      )
    end

    # Mirrors the manual-run controller's owner-scoped selection: a recovery
    # is a manual operator action, not a background late-binding selection.
    def runner_for(goal)
      owner = issue.project.effective_owner
      return unless owner

      configured = UserSetting.enabled_agent_runners(owner, identifiers: true)
      preferred = owner.settings.runner_priority_for_goal(goal, identifiers: true)
      identifier = configured.include?(preferred.first) ? preferred.first : preferred.first || configured.first
      Runner.for_identifier(owner, identifier) || Runner.ensure_default_for(owner)
    end

    def record_validation
      ManualReviewDecision.find_or_create_by!(issue:, revision_digest: revision_digest) do |record|
        record.project = issue.project
        record.actor = actor
        record.cause = ManualReviewDecision::REOPEN_REVIEW
        record.decision = decision
        record.reason = reason
      end
    end

    def revision_digest
      Digest::SHA256.hexdigest([ issue.title, issue.body, issue.github_updated_at&.utc&.iso8601 ].join("\n"))
    end

    def valid_intent_decision?
      decision.in?([ ManualReviewDecision::INTENT_VALID, ManualReviewDecision::INTENT_CHANGED ])
    end

    def dependency_message
      dependencies = ManualReviewCause.dependencies_for(issue)
      "Dependencies remain unresolved: #{dependencies.map(&:action).join(' ')}"
    end

    def wrong_action(classification)
      failure(:wrong_action, "This issue requires #{classification.primary.action.label.downcase} before it can continue.")
    end

    def failure(code, message) = Result.new(code:, message:)
  end
end
