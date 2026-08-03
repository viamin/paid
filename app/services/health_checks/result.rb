# frozen_string_literal: true

module HealthChecks
  # Aggregate result of one coordinator run.
  Result = Data.define(:findings, :checked_at, :duration_ms) do
    def initialize(findings:, checked_at: Time.current, duration_ms: 0)
      super
    end

    def healthy?
      findings.none?(&:error?)
    end

    def warnings?
      findings.any?(&:warning?)
    end

    def for_scope(scope)
      findings.select { |finding| finding.scope == scope.to_sym }
    end

    def counts
      findings.group_by(&:severity).transform_values(&:count)
    end

    def error_count
      counts.fetch(:error, 0)
    end

    def warning_count
      counts.fetch(:warning, 0)
    end
  end
end
