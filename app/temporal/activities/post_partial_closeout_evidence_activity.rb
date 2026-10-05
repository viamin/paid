# frozen_string_literal: true

module Activities
  # Posts the partial-closeout PR evidence on the still-open parent issue.
  #
  # Split from UpdateIssueWithPrActivity: when reconciliation leaves gaps, the
  # parent must stay incomplete (no completion, no trigger-label cleanup), but
  # the PR link must still be visible on the parent issue where the
  # dependency-blocked remaining work is tracked (#4119) — not only on the
  # internal AgentRun. The comment is marker-tagged per run and deduplicated,
  # so activity retries never double-post.
  class PostPartialCloseoutEvidenceActivity < BaseActivity
    activity_name "PostPartialCloseoutEvidence"

    def self.evidence_marker(agent_run_id)
      "<!-- paid:partial-closeout-pr:#{agent_run_id} -->"
    end

    def execute(input) # @spec NO-OUTPUT-ISSUE-007
      agent_run_id = input[:agent_run_id]
      pull_request_url = input[:pull_request_url]
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "post_partial_closeout_evidence",
        phase_group: "post", agent_run: agent_run) do
        issue = agent_run.issue

        return { agent_run_id: agent_run_id, posted: false } unless issue && pull_request_url.present?

        { agent_run_id: agent_run_id, posted: post_evidence_comment(agent_run, issue, pull_request_url) }
      end
    end

    private

    def post_evidence_comment(agent_run, issue, pull_request_url)
      project = agent_run.project
      return false if upstream_issue_write_skipped?(project, "post_partial_closeout_evidence", issue: issue, agent_run_id: agent_run.id)

      client = project.client
      return false if evidence_comment_present?(client, project, issue, self.class.evidence_marker(agent_run.id))

      client.add_comment(project.full_name, issue.github_number, comment_body(pull_request_url, agent_run.id))
      agent_run.log!("system", "Partial pull request evidence posted on issue ##{issue.github_number}")
      true
    rescue GithubClient::Error => e
      # NO-OUTPUT-ISSUE-007 requires the PR-evidence comment on the parent.
      # Swallowing a transient GitHub failure would complete the activity with
      # no Temporal retry and could permanently miss it, so re-raise: the
      # marker-deduplicated retry above keeps re-execution idempotent.
      logger.warn(
        message: "agent_execution.partial_closeout_evidence_comment_failed",
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        error: e.message
      )
      raise
    end

    # Restrict marker matching to Paid-authored comments when the author
    # identity is resolvable: the marker is unauthenticated plain text, so a
    # forged marker from another author must not suppress the evidence. When
    # neither identity is knowable, fall back to marker-only matching so
    # retries stay idempotent rather than duplicating comments forever.
    # A failed lookup must raise rather than report "absent": blind-posting
    # past an unreadable comment list could duplicate the evidence comment.
    def evidence_comment_present?(client, project, issue, marker)
      paid_login = paid_comment_author_login(client, project)
      client.recent_issue_comments(project.full_name, issue.github_number).any? do |comment|
        comment.body.to_s.include?(marker) && (paid_login.nil? || comment.user&.login&.downcase == paid_login)
      end
    end

    def paid_comment_author_login(client, project)
      project.github_author_login&.downcase || client.authenticated_login
    end

    def comment_body(pull_request_url, agent_run_id)
      [
        self.class.evidence_marker(agent_run_id),
        "**Partial pull request created: #{pull_request_url}**",
        "",
        "This pull request addresses part of this issue's acceptance criteria. " \
        "The remaining gaps are tracked as blocking dependencies of this issue; " \
        "it stays open and will be picked up again once they resolve."
      ].join("\n")
    end
  end
end
