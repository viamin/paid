# frozen_string_literal: true

namespace :issues do
  desc "Reset paid_state for issues parked in recommend_close by the false-positive classifier (iterations=0 + cost>0). Use DRY_RUN=false to apply."
  task reset_false_positive_recommend_close: :environment do
    dry_run = ENV.fetch("DRY_RUN", "true") != "false"
    candidates = []

    # Goal allowlist mirrors the workflow path that routes through
    # HandleNoOutputIssueRunActivity: any issue-based run with no source
    # PR can reach the classifier. analyze_issue takes a different path
    # (paid_state: "analyzed") and never sets recommend_close, but listing
    # both create_pr and enhance_issue here avoids missing future goals
    # added to the no-output classifier path.
    classifier_goals = %w[create_pr enhance_issue]

    TenantContext.with_system_access do
      Issue.where(paid_state: "recommend_close", is_pull_request: false, github_state: "open").find_each do |issue|
        last = issue.agent_runs
          .where(goal: classifier_goals, status: "completed")
          .order(created_at: :desc)
          .first
        next unless last
        next unless last.iterations.to_i.zero?

        candidates << [ issue, last ]
      end

      puts "Found #{candidates.size} issue(s) with iterations=0 recommend_close runs (DRY_RUN=#{dry_run})"
      candidates.each do |issue, run|
        puts "  ##{issue.github_number} project=#{issue.project.full_name} run=#{run.id} iterations=#{run.iterations} cost_cents=#{run.cost_cents}"
        next if dry_run

        issue.update!(paid_state: "new")
      end

      puts dry_run ? "Dry run only. Re-run with DRY_RUN=false to apply." : "Done."
    end
  end
end
