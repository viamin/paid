# frozen_string_literal: true

module HealthChecks
  # A single detected problem from a health check.
  # The stable +code+ is the dedup/auto-resolve key when flowing into notifications.
  Finding = Data.define(
    :code,
    :scope,
    :severity,
    :title,
    :description,
    :remediation,
    :action_url,
    :subject_type,
    :subject_id,
    :metadata
  ) do
    SEVERITIES = %i[info warning error].freeze

    def initialize(code:, scope:, severity:, title:, description: nil, remediation: nil, action_url: nil, subject_type: nil, subject_id: nil, metadata: {})
      super
    end

    def error?   = severity == :error
    def warning? = severity == :warning
    def info?    = severity == :info
  end
end
