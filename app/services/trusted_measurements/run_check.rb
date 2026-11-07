# frozen_string_literal: true

module TrustedMeasurements
  # Collects one allowlisted, read-only, bounded check against a project's
  # own live data and persists the idempotent attempt/evidence row for it.
  #
  # Tenant scope comes from the caller: RunCheckJob runs under
  # ApplicationJob's automatic +with_tenant_context+ (resolved from the
  # job's +project_id+ argument), and the operator rake task wraps this call
  # in +TenantContext.with(project.account)+ itself. This service never
  # establishes or bypasses tenant context on its own.
  #
  # Idempotent by (project, check_key, check_version, deployed_revision,
  # criterion_key, external_issue_number): a retry, a duplicate enqueue, or a
  # routine re-check against the same deployed revision updates the same
  # row instead of accumulating duplicates. A new deployed revision earns a
  # new row, so a stale revision's result is never silently reinterpreted as
  # current.
  class RunCheck
    def self.call(...) = new(...).call

    def initialize(project:, check_key:, external_issue_number:, criterion_key:)
      @project = project
      @check_key = check_key
      @external_issue_number = external_issue_number
      @criterion_key = criterion_key
    end

    def call
      check_class = resolve_check_class
      return unauthorized! unless check_class

      attempt = find_or_create_attempt(check_class.version, DeploymentSignal.current)
      return record_unknown!(attempt, "missing_deployment_signal") if attempt.deployed_revision.blank?
      return record_unknown!(attempt, "source_issue_not_available") unless attempt.issue

      execute!(attempt, check_class)
      reassess_closeout!(attempt)
      attempt
    end

    private

    attr_reader :project, :check_key, :external_issue_number, :criterion_key

    def resolve_check_class
      TrustedMeasurements.check_class(check_key)
    rescue TrustedMeasurements::UnknownCheckError
      nil
    end

    def unauthorized!
      Escalate.unauthorized(project: project, check_key: check_key, external_issue_number: external_issue_number, criterion_key: criterion_key)
      nil
    end

    def find_or_create_attempt(version, revision)
      # PostgreSQL treats NULLs as distinct in a unique index. The project row
      # lock therefore also serializes missing-revision requests, preserving
      # idempotency for duplicate deploy events before a signal is configured.
      project.with_lock do
        TrustedMeasurementAttempt.find_or_create_by!(
          project: project, check_key: check_key, check_version: version, deployed_revision: revision,
          criterion_key: criterion_key, external_issue_number: external_issue_number,
          issue: source_issue
        ) { |record| record.account = project.account }
      end
    end

    def source_issue
      @source_issue ||= project.issues.find_by(github_number: external_issue_number)
    end

    def record_unknown!(attempt, reason)
      attempt.update!(status: "unknown", result: {}, failure_reason: reason, executed_at: Time.current,
        consecutive_failure_count: 0)
      attempt
    ensure
      Escalate.call(attempt: attempt) if attempt&.persisted?
    end

    # Always re-runs the read: the check is side-effect free, and a bounded
    # re-check against the same revision is how a closed-but-stale count
    # (e.g. a reconciliation sweep that resolves more notifications between
    # two runs) gets picked up without creating a second row for the same
    # revision (@spec TRUSTED-MEASUREMENTS-004).
    def execute!(attempt, check_class)
      outcome = check_class.call(project: project)
      attempt.update!(
        status: "succeeded",
        result: outcome.to_h.stringify_keys,
        failure_reason: nil,
        executed_at: Time.current,
        consecutive_failure_count: 0
      )
      attempt
    rescue StandardError => error
      attempt.update!(
        status: "failed", failure_reason: error.message.to_s.truncate(500), executed_at: Time.current,
        consecutive_failure_count: attempt.consecutive_failure_count + 1
      )
      raise
    ensure
      Escalate.call(attempt: attempt) if attempt.persisted?
    end

    # A live result changes the evidence digest, which makes any prior
    # closeout assessment stale. Reuse the established bounded audit admission
    # rather than declaring the criterion satisfied here: the assessment
    # remains the sole authority that can release its matching prerequisite.
    def reassess_closeout!(attempt)
      PartialCloseouts::AutoAudit.call(issue: attempt.issue)
    end
  end
end
