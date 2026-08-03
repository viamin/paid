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
  # Finding (code +:health_check_internal_error+, severity +error+) instead of
  # failing the whole run.
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
      findings = run_checks
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      Result.new(findings: findings, checked_at: Time.current, duration_ms: elapsed_ms)
    end

    private

    attr_reader :scope, :subject, :include_network

    def run_checks
      checks = Registry.for_scope(scope).select { |c| include_network || !c.network? }
      all_findings = checks.flat_map { |check| run_safely(check, subject) }

      if scope == :project
        all_findings += compose_runner_findings
        all_findings += compose_user_findings
      end

      all_findings
    end

    def compose_runner_findings
      owner = subject.effective_owner
      return [] unless owner

      runner_checks = Registry.for_scope(:runner).select { |c| include_network || !c.network? }
      owner.runners.kept_only.for_agent_runs.flat_map do |runner|
        runner_checks.flat_map { |check| run_safely(check, runner) }
      end
    end

    def compose_user_findings
      owner = subject.effective_owner
      return [] unless owner

      user_checks = Registry.for_scope(:user).select { |c| include_network || !c.network? }
      user_checks.flat_map { |check| run_safely(check, owner) }
    end

    def run_safely(check, subj)
      check.call(subj)
    rescue => e
      check_name = check.name || check.to_s
      message = "#{check_name} raised #{e.class}: #{e.message}"
      Rails.logger.error(message: "health_checks.coordinator.check_error", check: check_name, error: e.class, error_message: e.message)

      [
        Finding.new(
          code: INTERNAL_ERROR_CODE,
          scope: check.scope,
          severity: :error,
          title: "Internal health check error",
          description: message,
          subject_type: subj.class.name,
          subject_id: subj.respond_to?(:id) ? subj.id : nil,
          metadata: { check_class: check_name, error_class: e.class.name }
        )
      ]
    end
  end
end
