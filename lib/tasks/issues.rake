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

  desc "Idempotently link create_pr runs to their generated PRs (repairs a missing parent_issue_id), " \
    "then cancels any queued run the repair reveals as a now-provable duplicate (#4052). " \
    "Ambiguous PR/issue histories are reported, never guessed. Scope with PROJECT_ID=<id>; DRY_RUN=false to apply."
  task repair_pull_request_source_links: :environment do # @spec EAGER-QUEUE-012
    dry_run = ENV.fetch("DRY_RUN", "true") != "false"
    linked_source_issue_ids = []
    ambiguous_count = 0

    TenantContext.with_system_access do
      scope = Issue.pull_requests_only.where(parent_issue_id: nil)
      scope = scope.where(project_id: ENV["PROJECT_ID"]) if ENV["PROJECT_ID"].present?

      scope.find_each do |pull_request|
        candidates = Issues::ReconcilePullRequestSource.candidate_source_issues(pull_request)
        next if candidates.empty?

        if candidates.size > 1
          ambiguous_count += 1
          puts "  AMBIGUOUS PR ##{pull_request.github_number} (project=#{pull_request.project.full_name}): " \
            "#{candidates.size} conflicting source issues #{candidates.map(&:id)} — left unlinked"
          next
        end

        source = candidates.first
        puts "  PR ##{pull_request.github_number} (project=#{pull_request.project.full_name}) -> issue ##{source.github_number}"
        next if dry_run

        pull_request.update!(parent_issue: source)
        linked_source_issue_ids << source.id
      end

      puts "Ambiguous: #{ambiguous_count}."
      if dry_run
        puts "Dry run only. Re-run with DRY_RUN=false to apply."
        next
      end

      puts "Linked #{linked_source_issue_ids.uniq.size} pull request(s)."

      # A repaired link can prove a queued run is now a duplicate (the exact
      # incident shape in #4052: a completed run's PR outlived the one-hour
      # sync grace period without ever getting linked). Route through the
      # normal recheck/cancel path instead of leaving it runnable.
      cancelled = 0
      AgentRun.where(issue_id: linked_source_issue_ids.uniq, status: "queued", auto_pick: true).find_each do |run|
        cancelled += 1 if AgentRuns::RecheckIssueEligibility.call(run)
      end
      puts "Cancelled #{cancelled} now-ineligible queued run(s)."
    end
  end

  desc "Reconcile legacy partial closeouts whose runs pre-date the " \
       "partial-closeout-reconciliation-v1 patch marker. Required: ACCOUNT_ID=<id>. " \
       "Optional: BATCH_SIZE=<n> (default 200) caps candidates per invocation; " \
       "AFTER_ID=<id> resumes from a prior run's next_cursor. Defaults to DRY_RUN=true, " \
       "which only scans and prints the candidate runs — no LLM call, no GitHub write. " \
       "Idempotent — repeat invocations with DRY_RUN=false finish runs whose prior attempt " \
       "recorded a `creating` marker, and skip runs whose reconciliation is terminal. " \
       "Re-invoke with AFTER_ID=<next_cursor> while next_cursor is present and " \
       "scanned == BATCH_SIZE to work through the full backlog (#4187, #4191)."
  task reconcile_legacy_partial_closeouts: :environment do # @spec PARTIAL-CLOSEOUT-015
    account_id = Integer(ENV.fetch("ACCOUNT_ID"))
    batch_size = Integer(ENV.fetch("BATCH_SIZE", PartialCloseouts::ReconcileLegacy::DEFAULT_BATCH_SIZE))
    # BATCH_SIZE=0 (or negative) scans nothing while `scanned == batch_size`
    # would still print an AFTER_ID continuation whose cursor never advances,
    # so reject it before invoking the service (#4191 review).
    abort "BATCH_SIZE must be a positive integer (got #{batch_size})" unless batch_size.positive?
    after_id = ENV["AFTER_ID"] && Integer(ENV["AFTER_ID"])
    dry_run = ENV.fetch("DRY_RUN", "true") != "false"

    # Every candidate that reaches `Reconcile` spends an
    # `Llm::AnalyzePartialCloseout` call and can file a real GitHub issue or
    # rewrite the parent issue's body. Unlike the sibling tasks above, this
    # sweep has no idempotent no-op mode of its own, so a misscoped
    # ACCOUNT_ID or an underestimated legacy backlog would otherwise mutate
    # a live repo before an operator sees the candidate set. Mirror
    # reset_false_positive_recommend_close / repair_pull_request_source_links:
    # default to a dry run that only lists candidates (#4191 review).
    if dry_run
      candidates = PartialCloseouts::ReconcileLegacy.preview(account_id: account_id, batch_size: batch_size, after_id: after_id)
      puts "Legacy partial closeout reconciliation for account #{account_id} (DRY_RUN=true):"
      puts "  scanned:     #{candidates.size}"
      candidates.each { |candidate| puts "    run=#{candidate.id} issue_id=#{candidate.issue_id}" }
      next_cursor = candidates.last&.id
      puts "  next_cursor: #{next_cursor}"
      puts "  More candidates may remain — re-run with AFTER_ID=#{next_cursor} to continue." if candidates.size == batch_size
      puts "Dry run only — no LLM calls or GitHub writes were made. Re-run with DRY_RUN=false to apply."
      next
    end

    result = PartialCloseouts::ReconcileLegacy.call(account_id: account_id, batch_size: batch_size, after_id: after_id)

    puts "Legacy partial closeout reconciliation for account #{account_id}:"
    if result.lock_held
      puts "Another reconciliation for account #{account_id} is in progress; no work was done. Re-run later."
      next
    end

    puts "  scanned:             #{result.scanned}"
    puts "  reconciled:          #{result.reconciled}"
    puts "  awaiting_operator:   #{result.awaiting_operator}"
    puts "  retryable_failure:   #{result.retryable_failure}"
    puts "  skipped:             #{result.skipped}"
    puts "  next_cursor:         #{result.next_cursor}"
    if result.scanned == batch_size
      puts "  More candidates may remain — re-run with AFTER_ID=#{result.next_cursor} to continue."
    end
  end
end
