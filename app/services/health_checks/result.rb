# frozen_string_literal: true

module HealthChecks
  Result = Data.define(:findings, :checked_at, :duration_ms) do
    def healthy?  = findings.none? { |f| f.severity == :error }
    def warnings? = findings.any? { |f| f.severity == :warning }
    def for_scope(s) = findings.select { |f| f.scope == s.to_sym }
    def counts  = findings.group_by(&:severity).transform_values(&:count)
  end
end
