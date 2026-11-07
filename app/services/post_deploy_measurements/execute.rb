# frozen_string_literal: true

module PostDeployMeasurements
  # Executes one trusted post-deploy measurement: resolves the deployment
  # gate, probes required capabilities, runs the allowlisted check's
  # read-only bounded queries with read-only enforcement, records the
  # inspectable evidence, escalates only the conditions the design names,
  # and feeds a current pass into the prerequisite reconciliation path. A
  # missing deployment, an unavailable capability, or an execution error
  # never fabricates a pass.
  # @spec POST-DEPLOY-003 @spec POST-DEPLOY-004 @spec POST-DEPLOY-005
  # @spec POST-DEPLOY-007
  class Execute
    Result = Data.define(:measurement, :status)

    # Raised when a check's queries are not read-only; classified as an
    # execution failure (unknown), never a pass.
    class ReadOnlyViolation < StandardError; end

    IGNORED_STATEMENT_NAMES = %w[SCHEMA TRANSACTION CACHE].freeze

    def self.call(...) = new(...).call

    def initialize(measurement:)
      @measurement = measurement
    end

    def call
      check = nil
      measurement.with_lock do
        return Result.new(measurement: measurement, status: measurement.status) unless executable?

        check = Registry.find(measurement.check_key)
        return unknown_check unless check&.version == measurement.check_version
        return authorization_failure unless authorized?

        measurement.update!(status: "running", attempts: measurement.attempts + 1)
      end

      run(check)
      Result.new(measurement: measurement.reload, status: measurement.status)
    end

    private

    attr_reader :measurement

    # Terminal rows are never re-executed; retry-eligible unknown rows are
    # picked up again by the sweep rather than re-run inline.
    def executable?
      !measurement.terminal? || measurement.retryable?
    end

    def unknown_check
      finish_unknown(
        reason: "Check #{measurement.check_key.inspect} v#{measurement.check_version} is not in the reviewed " \
                "allowlist at that version.",
        next_action: "Request a fresh measurement with the current check version."
      )
      Result.new(measurement: measurement.reload, status: measurement.status)
    end

    def authorization_failure
      finish_unknown(
        reason: "The measurement's account or project authorization no longer holds.",
        next_action: "Verify the project still belongs to the measurement's account and the account is active, " \
                     "then request the measurement again."
      )
      Result.new(measurement: measurement.reload, status: measurement.status)
    end

    def authorized?
      measurement.project.present? &&
        measurement.project.account_id == measurement.account_id &&
        measurement.issue.project_id == measurement.project_id &&
        measurement.account.status == "active"
    end

    def run(check)
      target = DeploymentTarget.resolve(measurement.issue)
      return awaiting_deployment(target) unless target.deployed?

      unavailable = Capabilities.first_unavailable(check.capabilities, project: measurement.project)
      return capability_unavailable(unavailable) if unavailable

      measured, duration_ms = measure_read_only(check)
      record_result(check, target, measured, duration_ms)
    rescue StandardError => error
      execution_failure(error)
    end

    def awaiting_deployment(target)
      measurement.update!(
        status: "awaiting_deployment",
        details: measurement.details.merge("next_action" => target.recovery,
          "deployment" => target.to_h.stringify_keys)
      )
      log(:info, "post_deploy_measurement.awaiting_deployment")
    end

    def capability_unavailable(unavailable)
      finish_unknown(
        reason: "Required capability #{unavailable.name.inspect} is unavailable.",
        next_action: unavailable.recovery
      )
    end

    # Read-only is enforced twice: the statement guard below rejects any
    # non-SELECT everywhere, and at the top transaction level the database
    # itself is put into READ ONLY mode so a write cannot even plan.
    def measure_read_only(check)
      statements = []
      measured = nil
      connection = ActiveRecord::Base.connection
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      subscriber = lambda do |_name, _started, _finished, _id, payload|
        next if IGNORED_STATEMENT_NAMES.include?(payload[:name]) || payload[:cached]

        statements << payload[:sql]
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        connection.transaction(requires_new: true) do
          connection.execute("SET TRANSACTION READ ONLY") if connection.open_transactions == 1
          measured = check.measurer.measure(project: measurement.project)
        end
      end
      assert_read_only!(statements)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
      [ measured, duration_ms ]
    end

    # Transaction-control statements (savepoints, begin/commit) are not data
    # writes; every data statement must be a read.
    READ_ONLY_PATTERN = /\A\s*(SELECT|WITH|EXPLAIN|SHOW|SET|SAVEPOINT|RELEASE|BEGIN|COMMIT|ROLLBACK)\b/i
    private_constant :READ_ONLY_PATTERN

    def assert_read_only!(statements)
      writable = statements.reject { |sql| sql.match?(READ_ONLY_PATTERN) }
      return if writable.empty?

      raise ReadOnlyViolation, "check #{measurement.check_key} attempted a non-read-only statement: #{writable.first.to_s.squish[0, 200]}"
    end

    def record_result(check, target, measured, duration_ms)
      passed = measured.actionable_count == check.target
      measurement.update!(
        status: passed ? "passed" : "failed",
        deployed_revision: target.revision,
        deployed_pr_number: target.pr_number,
        deployed_at: target.deployed_at,
        executed_at: Time.current,
        duration_ms: duration_ms,
        counts: measured.counts,
        details: measurement.details.merge(
          "scope" => measured.scope,
          "deployment" => { "revision" => target.revision, "pr_number" => target.pr_number,
                            "deployed_at" => target.deployed_at&.utc&.iso8601 },
          "comparison" => { "baseline" => check.baseline, "target" => check.target,
                            "measured" => measured.actionable_count },
          "next_action" => if passed
                             "Evidence recorded; the matching prerequisite is released by reconciliation."
                           else
                             "The live measurement contradicts the criterion."
                           end
        ),
        failure_reason: nil
      )
      passed ? ReconcileResult.call(measurement.reload) : escalate_contradiction(check, measured)
      bump_inbox_cache
      log(passed ? :info : :warn, "post_deploy_measurement.#{passed ? 'passed' : 'failed'}")
    end

    def execution_failure(error)
      retryable = measurement.attempts < PostDeployMeasurement::MAX_ATTEMPTS
      measurement.update!(
        status: "unknown",
        executed_at: Time.current,
        failure_reason: "#{error.class.name}: #{error.message}".truncate(2_000),
        details: measurement.details.merge(
          "next_action" => if retryable
                             "Execution failed; the sweep retries the measurement."
                           else
                             "Execution failed repeatedly; review the recorded failure and re-request the " \
                             "measurement after fixing it."
                           end
        )
      )
      escalate_persistent_failure unless retryable
      bump_inbox_cache
      log(:warn, "post_deploy_measurement.execution_failed")
    end

    def escalate_contradiction(check, measured)
      publish_escalation(
        title: "Post-deploy measurement contradicts issue ##{measurement.issue.github_number}'s acceptance criterion",
        reason: "The live count (#{measured.actionable_count}) does not meet the target (#{check.target}); " \
                "the deployment did not produce the expected result.",
        next_action: "Review the counted notifications for issue ##{measurement.issue.github_number}, " \
                     "reconcile or reopen the remaining work, then request the measurement again after the next deployment."
      )
    end

    def escalate_persistent_failure
      publish_escalation(
        title: "Post-deploy measurement keeps failing for issue ##{measurement.issue.github_number}",
        reason: measurement.failure_reason.to_s,
        next_action: measurement.details.fetch("next_action")
      )
    end

    def publish_escalation(title:, reason:, next_action:)
      Notifications::Publish.call(
        account: measurement.account, subject: measurement.issue,
        source: ESCALATION_NOTIFICATION_SOURCE, severity: :error, blocking: false,
        title: title, description: [ reason, "Next action: #{next_action}" ].join("\n\n"),
        metadata: { "measurement_id" => measurement.id, "check_key" => measurement.check_key,
                    "recommended_action" => next_action }
      )
      log(:warn, "post_deploy_measurement.escalated")
    end

    def finish_unknown(reason:, next_action:)
      measurement.update!(
        status: "unknown",
        executed_at: Time.current,
        failure_reason: reason,
        details: measurement.details.merge("next_action" => next_action)
      )
      publish_escalation(
        title: "Post-deploy measurement cannot run for issue ##{measurement.issue.github_number}",
        reason: reason, next_action: next_action
      )
      bump_inbox_cache
      log(:warn, "post_deploy_measurement.unknown")
    end

    def bump_inbox_cache
      Dashboard::CacheVersion.bump(measurement.account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
    end

    def log(level, message)
      Rails.logger.public_send(level,
        message: message,
        account_id: measurement.account_id,
        project_id: measurement.project_id,
        issue_id: measurement.issue_id,
        measurement_id: measurement.id,
        check_key: measurement.check_key,
        check_version: measurement.check_version,
        status: measurement.reload.status
      )
    end
  end
end
