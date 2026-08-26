# frozen_string_literal: true

module PageLoadPerformance
  # One route's before/after result. `status` is what the pull request comment
  # renders and what decides whether a finding exists:
  #
  # - `regressed`      — slower than baseline past both thresholds
  # - `unchanged`      — compared, within threshold (improvements included)
  # - `no_baseline`    — no earlier capture of this route on this pull request
  # - `not_comparable` — path, HTTP status, or viewport differed
  #
  # @spec PAGE-LOAD-REGRESSION-007
  Comparison = Data.define(
    :route_name, :status, :metric, :baseline_ms, :current_ms, :delta_ms,
    :trailing_median_ms, :finding
  ) do
    def regressed? = status == "regressed"

    def comparable? = %w[regressed unchanged].include?(status)
  end
end
