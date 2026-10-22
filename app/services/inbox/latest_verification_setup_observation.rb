# frozen_string_literal: true

module Inbox
  # Newest verification setup observation recorded for a project whose reason is
  # still an actionable readiness gap, or nil when no run recorded one.
  #
  # Ordering uses the recorder-owned `readiness_observation.observed_at` event
  # timestamp rather than the run's `created_at`: an older, long-running
  # verification run can record its setup failure after a newer run already
  # recorded the same failure, and creation order would then show the operator
  # stale diagnostic evidence. Matching rows are narrowed by reason in the
  # query itself, so no run-count cutoff can hide a later observation, and
  # observations without a recorded time sort last (they still surface when they
  # are the only evidence).
  # @spec PROJECT-READINESS-012
  class LatestVerificationSetupObservation
    OBSERVATION_KEY = "readiness_observation"
    OBSERVATION_SQL = "verification_result -> '#{OBSERVATION_KEY}'"
    # `::` binds tighter than `->>`, so the extraction must be parenthesized
    # before the cast; without them Postgres casts the literal key instead.
    OBSERVED_AT_SQL = "(#{OBSERVATION_SQL} ->> 'observed_at')::timestamptz"
    REASON_SQL = "#{OBSERVATION_SQL} ->> 'reason'"
    NEWEST_OBSERVED_AT_SQL = Arel.sql("#{OBSERVED_AT_SQL} DESC NULLS LAST")

    def self.call(...)
      new(...).call
    end

    def initialize(project:, reasons:)
      @project = project
      @reasons = reasons.compact.map(&:to_s).uniq
    end

    def call
      return if reasons.empty?

      run = observed_runs.order(NEWEST_OBSERVED_AT_SQL, id: :desc).first
      run&.verification_result&.fetch(OBSERVATION_KEY, nil)
    end

    private

    attr_reader :project, :reasons

    def observed_runs
      project.agent_runs
        .where("#{REASON_SQL} IN (?)", reasons)
        .select(:id, :verification_result)
    end
  end
end
