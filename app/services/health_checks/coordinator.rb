# frozen_string_literal: true

module HealthChecks
  # Runs the registered checks for a scope against a subject and aggregates
  # their findings into a single Result. Each check is isolated: a raising
  # check becomes an internal-error Finding instead of failing the run, so one
  # broken check cannot hide the others' results.
  #
  # A :project run composes all three scopes (RDR-049): it runs the project
  # checks on the project itself, the runner checks over the project's
  # effective owner's agent-eligible runners, and the user checks over that
  # effective owner — so one project health report spans project, runner, and
  # user settings.
  #
  # Network checks (those that hit GitHub / the model registry) are skipped
  # unless +include_network+ is true. They run only from the scheduled sweep
  # job, never synchronously in a request.
  #
  # +owner_findings_cache+ memoizes the runner/user findings composed for a
  # :project run, keyed by owner id. Runner and user findings depend only on
  # the project's effective owner, not the project itself, so a caller that
  # sweeps many projects (e.g. AccountHealthCheckSweepJob) should pass in one
  # Hash shared across calls to avoid recomputing the same owner's findings
  # — including network-backed checks — once per project.
  #
  # +effective_owner+ lets a caller pass a pre-resolved owner for a :project
  # run instead of falling back to +subject.effective_owner+. Project#effective_owner
  # falls back to Account#fallback_owner for orphaned projects (no created_by),
  # which queries account_memberships/users per call — a caller sweeping many
  # projects should batch-resolve fallback owners once and pass the result
  # here to avoid a query per orphaned project.
  class Coordinator
    INTERNAL_ERROR_CODE = :health_check_internal_error

    def self.call(scope:, subject:, include_network: false, owner_findings_cache: {}, effective_owner: nil)
      new(
        scope: scope,
        subject: subject,
        include_network: include_network,
        owner_findings_cache: owner_findings_cache,
        effective_owner: effective_owner
      ).call
    end

    def initialize(scope:, subject:, include_network: false, owner_findings_cache: {}, effective_owner: nil)
      @scope = scope
      @subject = subject
      @include_network = include_network
      @owner_findings_cache = owner_findings_cache
      @effective_owner = effective_owner
    end

    def call
      started_at = monotonic_clock

      Result.new(
        findings: compose_findings,
        checked_at: Time.current,
        duration_ms: elapsed_ms(started_at)
      )
    end

    private

    attr_reader :scope, :subject, :include_network

    def compose_findings
      return run_scope(scope, subject) unless scope == :project

      run_scope(:project, subject) + owner_scope_findings
    end

    def owner_scope_findings
      owner = effective_owner
      return [] unless owner

      owner_findings_cache[owner.id] ||= begin
        run_runner_checks(owner) + run_scope(:user, owner)
      end
    end

    def run_runner_checks(owner)
      checks = scoped_checks(:runner)
      return [] if checks.empty?

      owner.runners.kept_only.for_agent_runs.flat_map do |runner|
        run_checks(checks, runner)
      end
    end

    def run_scope(check_scope, check_subject)
      run_checks(scoped_checks(check_scope), check_subject)
    end

    def run_checks(checks, check_subject)
      checks.flat_map { |check| run_safely(check, check_subject) }
    end

    def scoped_checks(check_scope)
      Registry.for_scope(check_scope).select { |check| include_network || !check.network? }
    end

    def run_safely(check_class, check_subject)
      check_class.call(check_subject)
    rescue => e
      Rails.logger.error(
        message: "health_checks.coordinator.check_error",
        check: check_class.name || check_class.to_s,
        error: e.class.name,
        error_message: e.message
      )

      [ internal_error_finding(check_class, check_subject, e) ]
    end

    def internal_error_finding(check_class, check_subject, error)
      Finding.new(
        code: INTERNAL_ERROR_CODE,
        scope: check_class.scope,
        severity: :error,
        title: "Internal health check error",
        description: "#{check_class.name || check_class} raised #{error.class}: #{error.message}",
        remediation: "Re-run the health checks. If this persists, investigate the check implementation.",
        subject_type: check_subject.class.name,
        subject_id: check_subject.try(:id),
        metadata: { check_class: check_class.name || check_class.to_s, error_class: error.class.name }
      )
    end

    def owner_findings_cache
      @owner_findings_cache
    end

    def effective_owner
      @effective_owner || subject.effective_owner
    end

    def monotonic_clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end
  end
end
