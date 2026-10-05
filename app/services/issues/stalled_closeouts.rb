# frozen_string_literal: true

module Issues
  # Queues the stalled issues of the partial_closeout Inbox lane (#4120):
  # open, non-PR issues carrying terminal closeout evidence (a merged partial
  # PR or a no-code-required outcome) that auto-pick excludes, with no
  # explicit operator hold and no work in flight.
  #
  # Admission authority stays with
  # `DefaultCandidateSource.eligible_scope` — one batched call per project —
  # and {CloseoutStatus} supplies the per-issue explanation. Returns
  # [issue, status] pairs so list and count surfaces share one computation.
  # @spec PARTIAL-CLOSEOUT-002
  class StalledCloseouts
    Pair = Struct.new(:issue, :status, keyword_init: true)

    def self.call(projects)
      projects.flat_map { |project| pairs_for(project) }
    end

    def self.pairs_for(project)
      candidates = candidates_for(project).to_a
      return [] if candidates.empty?

      eligible_ids = Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(project).pluck(:id).to_set

      candidates.filter_map do |issue|
        status = CloseoutStatus.call(issue, eligible_issue_ids: eligible_ids)
        Pair.new(issue: issue, status: status) if status.stalled?
      end
    end

    # Cheap SQL prefilter on indexed state columns; the precise evidence and
    # blocker checks run per candidate in CloseoutStatus. Includes both
    # merged-evidence sources (parent-linked and run-recorded) so the
    # prefilter only ever over-includes, never drops, real stalls.
    def self.candidates_for(project)
      blocking_issue_ids = AgentRun.where(
        project: project, status: AgentRun::AUTO_PICK_BLOCKING_STATUSES
      ).where.not(issue_id: nil).select(:issue_id)

      project.issues.includes(:project)
        .where(github_state: "open", is_pull_request: false, paused: false)
        .where.not(paid_state: %w[needs_input manual_review])
        .where(runner_retry_abandoned_at: nil)
        .where.not(id: blocking_issue_ids)
        .where.not(id: IssueContinuationRequest.open.where(project: project).select(:issue_id))
        .where(closeout_evidence_sql)
    end

    def self.closeout_evidence_sql
      <<~SQL.squish
        issues.no_code_required_at IS NOT NULL
        OR EXISTS (
          SELECT 1 FROM issues merged_prs
          WHERE merged_prs.project_id = issues.project_id
            AND merged_prs.parent_issue_id = issues.id
            AND merged_prs.is_pull_request = TRUE
            AND merged_prs.pr_review_phase = 'merged'
        )
        OR EXISTS (
          SELECT 1 FROM agent_runs evidence_runs
          INNER JOIN issues run_prs
            ON run_prs.project_id = evidence_runs.project_id
           AND run_prs.github_number = evidence_runs.pull_request_number
           AND run_prs.is_pull_request = TRUE
           AND run_prs.pr_review_phase = 'merged'
          WHERE evidence_runs.project_id = issues.project_id
            AND evidence_runs.issue_id = issues.id
            AND evidence_runs.goal = 'create_pr'
            AND evidence_runs.pull_request_number IS NOT NULL
        )
      SQL
    end
  end
end
