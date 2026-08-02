# frozen_string_literal: true

module HealthChecks
  # Aggregate of one coordinator run. Cached by HealthChecks::Cache and read
  # by the project health page, so it must round-trip through Rails.cache
  # (Marshal) in production — keep it a plain immutable value object.
  Result = Data.define(:findings, :checked_at, :duration_ms) do
    def healthy?
      findings.none? { |finding| finding.severity == :error }
    end

    def error_count
      findings.count { |finding| finding.severity == :error }
    end

    def warning_count
      findings.count { |finding| finding.severity == :warning }
    end
  end
end
