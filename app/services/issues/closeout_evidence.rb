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
  # @spec PARTIAL-CLOSEOUT-001 PARTIAL-CLOSEOUT-047
  class CloseoutEvidence
    ISSUE_BODY_DIGEST_SQL = Arel.sql("encode(sha256(convert_to(COALESCE(issues.body, ''), 'UTF8')), 'hex')")
    MERGED_PR_BODY_DIGEST_SQL = Arel.sql("encode(sha256(convert_to(COALESCE(merged_prs.body, ''), 'UTF8')), 'hex')")
    MergedPullRequest = Struct.new(:number, :url, :terminal_at, :run_id, :body_digest, keyword_init: true)

    Result = Struct.new(:merged_prs, :no_code_required_at, :terminal_at, :digest, :pr_body_revision, keyword_init: true) do
      def present?
        merged_prs.any? || no_code_required_at.present?
      end
    end

    def self.call(issue)
      results_for([ issue ]).fetch(issue.id)
    end

    # Builds evidence for a lane's candidates with the same authoritative
    # joins as +call+, without issuing the two evidence queries per issue.
    def self.results_for(issues)
      return {} if issues.empty?

      issues_by_id = issues.index_by(&:id)
      issue_ids = issues_by_id.keys
      linked = Issue.where(project_id: issues.map(&:project_id).uniq, is_pull_request: true,
        pr_review_phase: "merged", parent_issue_id: issue_ids)
        .pluck(:parent_issue_id, :github_number, :github_html_url, :created_at, ISSUE_BODY_DIGEST_SQL)
      run_linked = linked_runs(issue_ids)
      merged_prs_by_issue_id = merged_prs_by_issue_id(issues_by_id, linked, run_linked)

      issues_by_id.transform_values do |issue|
        build_result(merged_prs_by_issue_id.fetch(issue.id, {}).values, issue.no_code_required_at)
      end
    end

    def self.digest_for(merged_prs, no_code_at)
      duplicate_numbers = merged_prs.group_by(&:number).filter_map { |number, prs| number if prs.size > 1 }.to_set
      canonical = [
        merged_prs.map do |pr|
          identity = duplicate_numbers.include?(pr.number) ? "#{pr.number}:#{pr.url}" : pr.number
          "merged:#{identity}@#{pr.terminal_at&.utc&.iso8601}"
        end.sort.join("|"),
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
      ).pluck(:github_number, :github_html_url, :created_at, :id, ISSUE_BODY_DIGEST_SQL)

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
        .pluck("agent_runs.id", "agent_runs.pull_request_number", "agent_runs.pull_request_url", "agent_runs.completed_at", "merged_prs.created_at", MERGED_PR_BODY_DIGEST_SQL)

      run_terminal_by_identity = run_linked.each_with_object({}) do |(_run_id, number, url, completed_at, _pr_created_at), map|
        identity = [ number, url ]
        existing = map[identity]
        map[identity] = completed_at if existing.nil? || (completed_at && completed_at > existing)
      end

      by_identity = {}

      linked.each do |number, html_url, pr_created_at, _pr_id, body_digest|
        url = html_url.presence || "#{issue.project.github_url}/pull/#{number}"
        by_identity[[ number, url ]] ||= MergedPullRequest.new(
          number: number,
          url: url,
          terminal_at: run_terminal_by_identity[[ number, url ]] || pr_created_at,
          run_id: nil,
          body_digest: body_digest
        )
      end

      run_linked.each do |run_id, number, pull_request_url, completed_at, pr_created_at, body_digest|
        pr = by_identity[[ number, pull_request_url ]]
        if pr.nil?
          # Use the run's recorded URL — the same field the join above
          # correlated — rather than reconstructing from issue.project.github_url,
          # which points at the fork. For pr_target: "upstream" the merged PR
          # lives in upstream_full_name, not in the project's own repo, so the
          # constructed fork URL would send the operator to a fork PR with
          # the same number that may be unrelated or open (#4130 review).
          by_identity[[ number, pull_request_url ]] = MergedPullRequest.new(
            number: number,
            url: pull_request_url.presence || "#{issue.project.github_url}/pull/#{number}",
            terminal_at: completed_at || pr_created_at,
            run_id: run_id,
            body_digest: body_digest
          )
        else
          pr.run_id = run_id
        end
      end

      by_identity.values
    end

    def self.build_result(merged_prs, no_code_at)
      terminal_at = (merged_prs.map(&:terminal_at).compact + [ no_code_at ]).compact.max
      Result.new(
        merged_prs: merged_prs.sort_by { |pr| [ pr.terminal_at || Time.at(0), pr.url, pr.number ] },
        no_code_required_at: no_code_at,
        terminal_at: terminal_at,
        digest: digest_for(merged_prs, no_code_at),
        pr_body_revision: merged_prs.any? ? Digest::SHA256.hexdigest(
          merged_prs.map { |pr| "#{pr.url}:#{pr.body_digest}" }.sort.join("|")) : nil
      )
    end
    private_class_method :build_result

    def self.linked_runs(issue_ids)
      AgentRun.where(goal: "create_pr", issue_id: issue_ids).where.not(pull_request_number: nil)
        .joins(<<~SQL.squish)
          INNER JOIN issues merged_prs
            ON merged_prs.project_id = agent_runs.project_id
           AND merged_prs.github_number = agent_runs.pull_request_number
          INNER JOIN projects merged_pr_projects ON merged_pr_projects.id = merged_prs.project_id
           AND (merged_prs.github_html_url = agent_runs.pull_request_url OR (
             merged_prs.github_html_url IS NULL AND agent_runs.pull_request_url = CONCAT(
               'https://github.com/', merged_pr_projects.owner, '/', merged_pr_projects.repo,
               '/pull/', merged_prs.github_number)))
           AND merged_prs.is_pull_request = TRUE AND merged_prs.pr_review_phase = 'merged'
        SQL
        .pluck("agent_runs.issue_id", "agent_runs.id", "agent_runs.pull_request_number",
          "agent_runs.pull_request_url", "agent_runs.completed_at", "merged_prs.created_at", MERGED_PR_BODY_DIGEST_SQL)
    end
    private_class_method :linked_runs

    def self.merged_prs_by_issue_id(issues_by_id, linked, run_linked)
      result = Hash.new { |hash, key| hash[key] = {} }
      run_times = run_linked.group_by { |issue_id, _run_id, number, url, *_rest| [ issue_id, number, url ] }
        .transform_values { |rows| rows.map { |row| row[4] }.compact.max }
      linked.each do |issue_id, number, url, created_at, body_digest|
        issue = issues_by_id.fetch(issue_id)
        url = url.presence || "#{issue.project.github_url}/pull/#{number}"
        result[issue_id][[ number, url ]] ||= MergedPullRequest.new(number:, url:, terminal_at: run_times[[ issue_id, number, url ]] || created_at, run_id: nil, body_digest:)
      end
      run_linked.each do |issue_id, run_id, number, url, completed_at, created_at, body_digest|
        url = url.presence || "#{issues_by_id.fetch(issue_id).project.github_url}/pull/#{number}"
        pr = result[issue_id][[ number, url ]]
        result[issue_id][[ number, url ]] = MergedPullRequest.new(number:, url:, terminal_at: completed_at || created_at, run_id:, body_digest:) if pr.nil?
        pr.run_id = run_id if pr
      end
      result
    end
    private_class_method :merged_prs_by_issue_id
  end
end
