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
  class Coordinator
    def self.call(scope:, subject:, include_network: false, owner_findings_cache: {})
      new(scope: scope, subject: subject, include_network: include_network,
          owner_findings_cache: owner_findings_cache).call
    end

    def initialize(scope:, subject:, include_network: false, owner_findings_cache: {})
      @scope = scope
      @subject = subject
      @include_network = include_network
      @owner_findings_cache = owner_findings_cache
    end

    def call
      started_at = monotonic_clock
      findings = collect_findings
      Result.new(findings: findings, checked_at: Time.current, duration_ms: elapsed_ms(started_at))
    end

    private

    def collect_findings
      findings = run_checks(@scope, @subject)
      findings += project_composed_findings if @scope == :project
      findings
    end

    def project_composed_findings
      owner = @subject.effective_owner
      return [] unless owner

      @owner_findings_cache[owner.id] ||= owner_scope_findings(owner)
    end

    def owner_scope_findings(owner)
      runner_findings = owner.runners.kept_only.for_agent_runs.flat_map { |runner| run_checks(:runner, runner) }
      runner_findings + run_checks(:user, owner)
    end

    def run_checks(scope, subject)
      applicable_checks(scope).flat_map { |check| run_safely(check, subject) }
    end

    def applicable_checks(scope)
      Registry.for_scope(scope).select { |check| @include_network || !check.network? }
    end

    def run_safely(check, subject)
      check.call(subject)
    rescue => e
      [ internal_error_finding(check, e) ]
    end

    def internal_error_finding(check, error)
      Finding.new(
        check: check.name,
        scope: check.scope,
        severity: :error,
        message: "Health check #{check.name} failed: #{error.message}"
      )
    end

    def monotonic_clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end
  end
end
