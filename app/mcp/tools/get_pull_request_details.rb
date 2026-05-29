# frozen_string_literal: true

module Tools
  class GetPullRequestDetails < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    def self.tool_name = "get_pull_request_details"

    def self.description
      "Get full pull request details including body, review status, and associated agent runs."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          issue_id: { type: "integer", description: "The PR's issue ID in Paid" }
        },
        required: %w[project_id issue_id]
      }
    end

    def perform(project_id:, issue_id:)
      project = project_for(project_id)

      pr = project.issues.pull_requests_only.find(issue_id)

      {
        id: pr.id,
        github_number: pr.github_number,
        title: pr.title,
        body: pr.body,
        github_state: pr.github_state,
        paid_state: pr.paid_state,
        pr_review_phase: pr.pr_review_phase,
        labels: pr.labels,
        github_creator_login: pr.github_creator_login,
        github_url: pr.github_url,
        comments: fetch_comments(project, pr),
        review_comments: fetch_review_comments(project, pr),
        agent_runs: pr.agent_runs.recent.limit(5).map { |r| run_summary(r) },
        github_created_at: pr.github_created_at,
        github_updated_at: pr.github_updated_at
      }
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def fetch_comments(project, pr)
      client = project.github_token&.client
      return [] unless client

      comments = client.recent_issue_comments(project.full_name, pr.github_number).last(20)
      comments.map do |c|
        { user: c.user.login, body: c.body, created_at: c.created_at }
      end
    rescue StandardError => e
      Rails.logger.warn(message: "mcp.fetch_pr_comments_failed", error: e.message, issue_id: pr.id)
      []
    end

    def fetch_review_comments(project, pr)
      client = project.github_token&.client
      return [] unless client

      comments = client.pull_request_review_comments(project.full_name, pr.github_number, per_page: 20)
      comments.map do |c|
        { user: c[:user_login], body: c[:body], path: c[:path], created_at: c[:created_at] }
      end
    rescue StandardError => e
      Rails.logger.warn(message: "mcp.fetch_pr_review_comments_failed", error: e.message, issue_id: pr.id)
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
