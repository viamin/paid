# frozen_string_literal: true

module Issues
  # Computes an issue's terminal closeout evidence — the merged-PR and
  # no-code-required outcomes that keep an open issue out of auto-pick
  # regardless of paid_state (EAGER-QUEUE-011 / AUTO-PICK-QUEUE-004) — and a
  # stable outcome-generation digest over that evidence.
  #
  # Terminal timestamps read `agent_runs.completed_at` (falling back to the PR
  # row's `created_at`), never `updated_at`, matching the immutability
  # rationale of DefaultCandidateSource#merged_pr_terminal_audit_at_by_issue_id:
  # later syncs bump PR `updated_at` and must not advance the evidence
  # generation.
  # @spec PARTIAL-CLOSEOUT-001
  class CloseoutEvidence
    MergedPullRequest = Struct.new(:number, :url, :terminal_at, :run_id, keyword_init: true)

    Result = Struct.new(:merged_prs, :no_code_required_at, :terminal_at, :digest, keyword_init: true) do
      def present?
        merged_prs.any? || no_code_required_at.present?
      end
    end

    def self.call(issue)
      merged_prs = merged_pull_requests(issue)
      no_code_at = issue.no_code_required_at
      terminal_at = (merged_prs.map(&:terminal_at).compact + [ no_code_at ]).compact.max

      Result.new(
        merged_prs: merged_prs.sort_by { |pr| [ pr.terminal_at || Time.at(0), pr.number ] },
        no_code_required_at: no_code_at,
        terminal_at: terminal_at,
        digest: digest_for(merged_prs, no_code_at)
      )
    end

    def self.digest_for(merged_prs, no_code_at)
      canonical = [
        merged_prs.map { |pr| "merged:#{pr.number}@#{pr.terminal_at&.utc&.iso8601}" }.sort.join("|"),
        "no_code:#{no_code_at&.utc&.iso8601}"
      ].join(";;")

      Digest::SHA256.hexdigest(canonical)
    end

    # Merged PR rows authoritatively linked to the issue: via parent_issue_id,
    # or via an originating create_pr run's recorded pull_request_number
    # matched through the repo-qualified URL join (same discipline as
    # Issue.paid_generated_pull_request_source_issue_ids so fork/upstream
    # number collisions cannot fabricate evidence; a run whose fork PR #42 is
    # open cannot be treated as terminal evidence by an upstream PR #42 in the
    # same project).
    def self.merged_pull_requests(issue)
      linked = Issue.where(
        project_id: issue.project_id,
        is_pull_request: true,
        pr_review_phase: "merged",
        parent_issue_id: issue.id
      ).pluck(:github_number, :github_html_url, :created_at, :id)

      run_linked = AgentRun.where(project_id: issue.project_id, goal: "create_pr", issue_id: issue.id)
        .where.not(pull_request_number: nil)
        .joins(<<~SQL.squish)
          INNER JOIN issues merged_prs
            ON merged_prs.project_id = agent_runs.project_id
           AND merged_prs.github_number = agent_runs.pull_request_number
          INNER JOIN projects merged_pr_projects
            ON merged_pr_projects.id = merged_prs.project_id
           AND (
             merged_prs.github_html_url = agent_runs.pull_request_url
             OR (
               merged_prs.github_html_url IS NULL
               AND agent_runs.pull_request_url = CONCAT(
                 'https://github.com/',
                 merged_pr_projects.owner,
                 '/',
                 merged_pr_projects.repo,
                 '/pull/',
                 merged_prs.github_number
               )
             )
           )
           AND merged_prs.is_pull_request = TRUE
           AND merged_prs.pr_review_phase = 'merged'
        SQL
        .pluck("agent_runs.id", "agent_runs.pull_request_number", "agent_runs.pull_request_url", "agent_runs.completed_at", "merged_prs.created_at")

      run_terminal_by_number = run_linked.each_with_object({}) do |(_run_id, number, _url, completed_at, _pr_created_at), map|
        existing = map[number]
        map[number] = completed_at if existing.nil? || (completed_at && completed_at > existing)
      end

      by_number = {}

      linked.each do |number, html_url, pr_created_at, _pr_id|
        by_number[number] ||= MergedPullRequest.new(
          number: number,
          url: html_url.presence || "#{issue.project.github_url}/pull/#{number}",
          terminal_at: run_terminal_by_number[number] || pr_created_at,
          run_id: nil
        )
      end

      run_linked.each do |run_id, number, _pull_request_url, completed_at, pr_created_at|
        pr = by_number[number]
        if pr.nil?
          by_number[number] = MergedPullRequest.new(
            number: number,
            url: "#{issue.project.github_url}/pull/#{number}",
            terminal_at: completed_at || pr_created_at,
            run_id: run_id
          )
        else
          pr.run_id = run_id
        end
      end

      by_number.values
    end
  end
end
