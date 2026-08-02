# frozen_string_literal: true

module HealthChecks
  # Aggregate result of one coordinator run.
  Result = Data.define(:findings, :checked_at, :duration_ms) do
    def initialize(findings:, checked_at: Time.current, duration_ms: 0)
      super
    end

    def healthy?
      findings.none? { |f| f.severity == :error }
    end

    def warnings?
      findings.any? { |f| f.severity == :warning }
    end

    def for_scope(scope)
      findings.select { |f| f.scope == scope }
    end

    def counts
      findings.group_by(&:severity).transform_values(&:count)
    end
  end
end
