# frozen_string_literal: true

FixtureKit.define do
  project = create(:project,
    auto_scan_prs: true,
    max_pr_followup_runs: 3,
    pr_action_labels: [],
    auto_fix_merge_conflicts: false)

  expose(project:)
end
