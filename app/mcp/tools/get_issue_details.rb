# frozen_string_literal: true

module Tools
  class GetIssueDetails < BaseTool
    def self.tool_name = "get_issue_details"

    def self.description
      "Get full issue details including body, labels, and associated agent runs."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          issue_id: { type: "integer", description: "The issue ID" }
        },
        required: %w[project_id issue_id]
      }
    end

    def call(project_id:, issue_id:)
      project = policy_scope(Project).find(project_id)
      authorize project, :show?

      issue = project.issues.find(issue_id)

      {
        id: issue.id,
        github_number: issue.github_number,
        title: issue.title,
        body: issue.body,
        github_state: issue.github_state,
        paid_state: issue.paid_state,
        labels: issue.labels,
        github_creator_login: issue.github_creator_login,
        is_pull_request: issue.is_pull_request,
        parent_issue_id: issue.parent_issue_id,
        comments: fetch_comments(project, issue),
        agent_runs: issue.agent_runs.recent.limit(5).map { |r| run_summary(r) },
        github_created_at: issue.github_created_at,
        github_updated_at: issue.github_updated_at
      }
    end

    private

    def fetch_comments(project, issue)
      client = project.github_token&.client
      return [] unless client

      comments = client.issue_comments(project.full_name, issue.github_number).first(20)
      comments.map do |c|
        { user: c.user.login, body: c.body, created_at: c.created_at }
      end
    rescue StandardError => e
      Rails.logger.warn(message: "mcp.fetch_comments_failed", error: e.message, issue_id: issue.id)
      []
    end

    def run_summary(run)
      {
        id: run.id,
        status: run.status,
        goal: run.goal,
        pull_request_url: run.pull_request_url,
        created_at: run.created_at
      }
    end
  end
end
