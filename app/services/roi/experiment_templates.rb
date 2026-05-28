# frozen_string_literal: true

module Roi
  class ExperimentTemplates
    ALL = [
      {
        key: "two_week_bug_fix_pilot",
        name: "2-week bug-fix pilot",
        duration: "14 days",
        motion: "Route a bounded stream of bug tickets through Paid and compare against the current human-only lane.",
        success_criteria: [
          "Higher merge rate on bug tickets",
          "Lower cycle time from issue open to accepted PR",
          "Lower cost per accepted PR than the current delivery path"
        ],
        benchmark_plan: "Capture one human-only benchmark entry before launch, then update weekly."
      },
      {
        key: "backlog_burndown_pilot",
        name: "Backlog burn-down pilot",
        duration: "21 days",
        motion: "Run Paid against a curated queue of aging backlog issues while maintaining a matched human baseline cohort.",
        success_criteria: [
          "More accepted PRs per week",
          "Stable or lower rework and defect escape rates",
          "Clear payback narrative for procurement and expansion review"
        ],
        benchmark_plan: "Track benchmark entries for the human lane and any commercial-agent comparison in the same period."
      }
    ].freeze
  end
end
