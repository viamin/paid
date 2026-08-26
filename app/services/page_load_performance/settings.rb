# frozen_string_literal: true

module PageLoadPerformance
  # Resolved per-project page load settings, read from
  # `screenshot_settings["performance"]`.
  #
  # @spec PAGE-LOAD-CONFIG-001
  class Settings
    DEFAULTS = {
      "enabled" => true,
      "followup_enabled" => false,
      "comparison_metric" => "lcp_ms",
      "regression_ratio" => 0.25,
      "regression_floor_ms" => 150,
      "samples" => 3
    }.freeze

    # Sampling stops when this much of the capture's time has gone into it;
    # remaining routes are measured once. Keeps a many-route pull request from
    # pushing capture past its timeout and losing the screenshots too.
    SAMPLE_BUDGET_SECONDS = 90

    def self.for(project)
      new(project.effective_screenshot_settings["performance"] || {})
    end

    def initialize(values)
      @values = DEFAULTS.merge(values.to_h.deep_stringify_keys)
    end

    def enabled? = @values["enabled"] == true

    def followup_enabled? = @values["followup_enabled"] == true

    def comparison_metric = @values["comparison_metric"]

    def regression_ratio = @values["regression_ratio"].to_f

    def regression_floor_ms = @values["regression_floor_ms"].to_i

    def samples = @values["samples"].to_i

    def sample_budget_seconds = SAMPLE_BUDGET_SECONDS

    def to_h = @values
  end
end
