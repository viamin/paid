# frozen_string_literal: true

module Activities
  # Completes an agent run that pushed to an existing PR's branch.
  # Marks the run as completed with the existing PR's URL/number
  # and adds a comment to the PR noting the agent pushed updates.
  class CompleteExistingPrRunActivity < BaseActivity
    activity_name "CompleteExistingPrRun"
    COMMENT_MARKER = "<!-- paid:agent-update -->"
    SUMMARY_PREFIX = "## Agent Update"
    GENERIC_MESSAGE = "Agent pushed updates to this PR."
    LEGACY_COMMENT_BODIES = [ SUMMARY_PREFIX, GENERIC_MESSAGE ].freeze

    class << self
      def agent_update_comment?(body)
        normalized = body.to_s
        normalized.include?(COMMENT_MARKER) ||
          LEGACY_COMMENT_BODIES.any? { |comment| normalized.include?(comment) }
      end
    end

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      project = agent_run.project
      client = project.github_token.client

      pr = client.pull_request(project.full_name, agent_run.source_pull_request_number)

      agent_run.complete!(
        result_commit: agent_run.result_commit_sha,
        pr_url: pr.html_url,
        pr_number: pr.number
      )

      post_update_comment(client, project, pr.number, agent_run)

      agent_run.log!("system", "Pushed updates to existing PR: #{pr.html_url}")

      issue = agent_run.issue
      if issue && !(issue.is_pull_request? && issue.draft_phase?)
        issue.update!(paid_state: "completed")
      end

      logger.info(
        message: "agent_execution.existing_pr_completed",
        agent_run_id: agent_run_id,
        pull_request_url: pr.html_url
      )

      ProcessRunQueueJob.perform_later

      { agent_run_id: agent_run_id, pull_request_url: pr.html_url, pull_request_number: pr.number,
        pr_review_phase: agent_run.issue&.pr_review_phase }
    end

    private

    def post_update_comment(client, project, pr_number, agent_run)
      body = build_comment_body(agent_run)

      client.add_comment(project.full_name, pr_number, body)
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.existing_pr_comment_failed",
        agent_run_id: agent_run.id,
        pr_number: pr_number,
        error: e.message
      )
    end

    def build_comment_body(agent_run)
      summary = agent_run.agent_summary

      if summary.present?
        "#{COMMENT_MARKER}\n#{SUMMARY_PREFIX}\n\n#{summary.truncate(50_000)}"
      else
        "#{COMMENT_MARKER}\n#{GENERIC_MESSAGE}"
      end
    end
  end
end
