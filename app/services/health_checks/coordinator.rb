# frozen_string_literal: true

module HealthChecks
  class Coordinator
    def self.call(scope:, subject:, include_network: false)
      new(scope: scope, subject: subject, include_network: include_network).call
    end

    def initialize(scope:, subject:, include_network: false)
      @scope = scope
      @subject = subject
      @include_network = include_network
    end

    def call
      started = monotonic_now
      Result.new(
        findings: compose_findings,
        checked_at: Time.current,
        duration_ms: elapsed_ms(started)
      )
    end

    private

    def compose_findings
      return run_scope(@scope, @subject) unless @scope == :project

      run_scope(:project, @subject) +
        run_scope(:user, @subject.effective_owner) +
        run_runner_checks
    end

    def run_runner_checks
      checks = scoped_checks(:runner)
      return [] if checks.empty?

      runners = @subject.effective_owner&.runners&.kept_only&.for_agent_runs || []
      runners.flat_map { |runner| run_checks(checks, runner) }
    end

    def run_scope(scope, subject)
      run_checks(scoped_checks(scope), subject)
    end

    def run_checks(checks, subject)
      checks.flat_map { |check| run_safely(check, subject) }
    end

    def scoped_checks(scope)
      Registry.for_scope(scope).select { |c| @include_network || !c.network? }
    end

    def run_safely(check_class, subject)
      check_class.call(subject)
    rescue => e
      [ internal_error_finding(check_class, e) ]
    end

    def internal_error_finding(check_class, error)
      Finding.new(
        code: check_class.code,
        scope: check_class.scope,
        severity: :error,
        title: "#{check_class.name.demodulize.titleize} check failed",
        description: "Check raised an unexpected error: #{error.message}",
        remediation: "Re-run the health checks. If this persists, investigate the check implementation.",
        metadata: { check: check_class.name, error: error.class.name }
      )
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end
  end
end
