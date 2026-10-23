# frozen_string_literal: true

module Issues
  # Queues the stalled issues of the partial_closeout Inbox lane (#4120):
  # open, non-PR issues carrying terminal closeout evidence (a merged partial
  # PR or a no-code-required outcome) that auto-pick excludes, with no
  # explicit operator hold and no work in flight.
  #
  # Admission authority stays with
  # `DefaultCandidateSource.partial_closeout_eligibility` — one shared input
  # build per project — and {CloseoutStatus} supplies the per-issue explanation. Returns
  # [issue, status] pairs so list and count surfaces share one computation.
  # @spec PARTIAL-CLOSEOUT-002
  class StalledCloseouts
    Pair = Struct.new(:issue, :status, keyword_init: true)

    # @spec OPERATOR-INBOX-016
    def self.call(projects, issue_id: nil)
      return [] if projects.empty?

      scope = candidates_for(projects)
      scope = scope.where(id: issue_id) if issue_id
      candidates_by_project = scope.to_a.group_by(&:project_id)
      projects.flat_map do |project|
        pairs_for(project, candidates: candidates_by_project.fetch(project.id, []))
      end
    end

    def self.pairs_for(project, candidates: candidates_for(project).to_a)
      return [] if candidates.empty?

      eligibility = Automation::Strategies::AutoPick::DefaultCandidateSource
        .partial_closeout_eligibility(project, issue_ids: candidates.map(&:id))
      # The scoped admission decision each candidate's continuation would
      # face at dequeue (`CloseoutStatus#residual_eligibility_blocker`),
      # evaluated from shared project inputs. The guards are per-issue, so
      # authorizing the plain-ineligible candidates at once yields each
      # candidate's own scoped verdict.
      candidates.filter_map do |issue|
        issue.project = project
        status = CloseoutStatus.call(
          issue,
          eligible_issue_ids: eligibility.eligible_ids,
          continuation_eligible_issue_ids: eligibility.continuation_eligible_ids
        )
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

      Issue.where(project: project)
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
          #{Issue::AUTO_PICK_MERGED_PR_CORRELATED_SUBQUERY}
        )
      SQL
    end
  end
end
