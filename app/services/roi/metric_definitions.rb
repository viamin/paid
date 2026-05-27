# frozen_string_literal: true

module Roi
  class MetricDefinitions
    ALL = [
      {
        key: :merge_rate,
        name: "Merge rate",
        objective: "maximize",
        description: "Accepted pull requests divided by created pull requests in the measurement window."
      },
      {
        key: :average_cycle_time_hours,
        name: "Cycle time",
        objective: "minimize",
        description: "Average elapsed hours from issue intake to accepted pull request."
      },
      {
        key: :rework_rate,
        name: "Rework rate",
        objective: "minimize",
        description: "Accepted pull requests that needed reruns, retries, or follow-up work."
      },
      {
        key: :defect_escape_rate,
        name: "Defect escape rate",
        objective: "minimize",
        description: "Accepted pull requests followed by additional issue work after acceptance."
      },
      {
        key: :cost_per_accepted_pr_cents,
        name: "Cost per accepted PR",
        objective: "minimize",
        description: "Total create-PR spend divided by accepted pull requests."
      }
    ].freeze
  end
end
