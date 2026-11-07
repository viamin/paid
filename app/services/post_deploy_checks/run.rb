# frozen_string_literal: true

module PostDeployChecks
  # Executes exactly one allowlisted, read-only, tenant-scoped check and
  # persists an idempotent attempt/evidence record keyed on check, project,
  # and deployed revision. Never fabricates a pass: a missing deployment
  # signal is recorded "unknown", and an execution error is recorded "failed"
  # — neither reaches "succeeded".
  # @spec POST-DEPLOY-CHECK-002 POST-DEPLOY-CHECK-003 POST-DEPLOY-CHECK-004
  # @spec POST-DEPLOY-CHECK-005 POST-DEPLOY-CHECK-006B POST-DEPLOY-CHECK-011
  class Run
    PERSISTENT_FAILURE_THRESHOLD = 3
    # Transient infrastructure errors retry on the next scheduled attempt and
    # only escalate once they persist; every other error is a bug in the
    # check or its authorization and escalates immediately (style guide:
    # classify every error as retryable or non-retryable).
    RETRYABLE_ERRORS = [ ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionTimeoutError ].freeze

    def self.call(...) = new(...).call

    def initialize(check_key:, project:, deployed_revision:, source_issue: nil)
      @check_class = Registry.fetch(check_key)
      @check_key = check_key.to_s
      @project = project
      @deployed_revision = deployed_revision.presence
      @source_issue = source_issue
    end

    def call
      require_authorized_context!
      run = find_or_initialize_run
      return run if run.succeeded?
      return record!(run, status: "unknown", reason: deployment_block_reason) if deployment_blocked?

      execute!(run)
    end

    private

    attr_reader :check_class, :check_key, :project, :deployed_revision, :source_issue

    # RLS on the measured tables (notifications/issues) silently returns zero
    # rows for an unestablished tenant context — a zero-row read would look
    # exactly like a passing measurement. Fail loud instead of persisting a
    # fabricated pass; there is no tenant-scoped way to record this failure
    # itself, so it is not caught below.
    def require_authorized_context!
      return if TenantContext.bypass_enabled?
      return if Current.account == project.account

      raise AuthorizationError, "No tenant context is established for account ##{project.account_id}; " \
        "run this check within TenantContext.with(account) or TenantContext.with_system_access."
    end

    def execute!(run)
      run.update!(status: "running", executed_at: Time.current)
      result = check_class.call(project: project)
      run = record!(run, status: "succeeded", result: result.to_h)
      supersede_prior_runs!(run)
      run
    rescue *RETRYABLE_ERRORS => error
      escalate_on_persistent_failure!(record!(run, status: "failed", reason: error.message))
    rescue StandardError => error
      escalate_now!(record!(run, status: "failed", reason: error.message), error)
    end

    def deployment_blocked?
      (source_issue && !source_issue.deployed?) || deployed_revision.blank?
    end

    def deployment_block_reason
      return "Source issue ##{source_issue.github_number} is not marked deployed yet." if source_issue && !source_issue.deployed?

      "No deployed revision was supplied for this check."
    end

    def idempotency_key
      "#{check_key}:v#{check_class::VERSION}:project#{project.id}:#{deployed_revision}"
    end

    def find_or_initialize_run
      PostDeployCheckRun.find_by(account_id: project.account_id, idempotency_key: idempotency_key) || create_run!
    end

    def create_run!
      PostDeployCheckRun.create!(account: project.account, project:, source_issue:, check_key:,
        check_version: check_class::VERSION, deployed_revision:, idempotency_key:, status: "pending")
    rescue ActiveRecord::RecordNotUnique
      PostDeployCheckRun.find_by!(account_id: project.account_id, idempotency_key: idempotency_key)
    end

    def record!(run, status:, result: {}, reason: nil)
      run.update!(status:, result:, failure_reason: reason, executed_at: Time.current)
      run
    end

    # A newer deployed revision's success retires every prior evidence row
    # for this check+project so a consumer reading `.current` never treats a
    # stale revision's result as today's answer.
    def supersede_prior_runs!(run)
      PostDeployCheckRun.current.where(account_id: project.account_id, project_id: project.id, check_key:)
        .where.not(id: run.id).update_all(superseded_by_id: run.id)
    end

    def escalate_now!(run, error)
      publish_failure!(run, "post_deploy_check_execution_failed",
        title: "Post-deploy check \"#{check_key}\" cannot run",
        description: "#{error.class.name}: #{error.message}",
        recommended_action: "Investigate and fix the failing check, or restore the authorization or " \
          "capability it needs, then re-run it for project #{project.full_name}.")
    end

    def escalate_on_persistent_failure!(run)
      recent = PostDeployCheckRun.where(account_id: project.account_id, project_id: project.id, check_key:)
        .order(created_at: :desc).limit(PERSISTENT_FAILURE_THRESHOLD).to_a
      return run unless recent.size == PERSISTENT_FAILURE_THRESHOLD && recent.all?(&:failed?)

      publish_failure!(run, "post_deploy_check_persistent_failure",
        title: "Post-deploy check \"#{check_key}\" has failed #{PERSISTENT_FAILURE_THRESHOLD} times in a row",
        description: "The check has not completed across #{PERSISTENT_FAILURE_THRESHOLD} attempts: #{run.failure_reason}",
        recommended_action: "Restore the database capability this check needs for project #{project.full_name}, then re-run it.")
    end

    def publish_failure!(run, source, title:, description:, recommended_action:)
      Notifications::Publish.call(account: project.account, source:, subject: project, severity: :error, blocking: true,
        title:, description:, metadata: { recommended_action:, check_key:, post_deploy_check_run_id: run.id })
      run
    end
  end
end
