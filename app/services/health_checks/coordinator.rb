# frozen_string_literal: true

module HealthChecks
  # Runs the registered checks for a scope against a subject and aggregates
  # their findings into a single Result. Each check is isolated: a raising
  # check becomes an internal-error Finding instead of failing the run, so one
  # broken check cannot hide the others' results.
  #
  # Network checks (those that hit GitHub / the model registry) are skipped
  # unless +include_network+ is true. They run only from the scheduled sweep
  # job, never synchronously in a request.
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
      started_at = monotonic_clock
      findings = applicable_checks.flat_map { |check| run_safely(check) }
      Result.new(findings: findings, checked_at: Time.current, duration_ms: elapsed_ms(started_at))
    end

    private

    def applicable_checks
      Registry.for_scope(@scope).select { |check| @include_network || !check.network? }
    end

    def run_safely(check)
      check.call(@subject)
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
