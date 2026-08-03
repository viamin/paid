# frozen_string_literal: true

module HealthChecks
  # Orchestrates health checks for a subject across scopes.
  #
  #   result = HealthChecks::Coordinator.call(scope: :project, subject: project)
  #
  # When +scope+ is +:project+, runner and user checks are composed automatically:
  #   - runner checks run against project.effective_owner.runners.kept_only.for_agent_runs
  #   - user checks run against project.effective_owner
  #
  # Each check is isolated: a raise inside one check becomes an internal-error
  # Finding instead of failing the whole run.
  class Coordinator
    INTERNAL_ERROR_CODE = :health_check_internal_error

    def self.call(scope:, subject:, include_network: false)
      new(scope: scope, subject: subject, include_network: include_network).call
    end

    def initialize(scope:, subject:, include_network: false)
      @scope = scope
      @subject = subject
      @include_network = include_network
    end

    def call
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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

      run_scope(:project, subject) +
        run_user_checks +
        run_runner_checks
    end

    def run_user_checks
      owner = subject.effective_owner
      return [] unless owner

      run_scope(:user, owner)
    end

    def run_runner_checks
      owner = subject.effective_owner
      return [] unless owner

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

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end
  end
end
