# frozen_string_literal: true

module Tools
  class GetProjectPullRequests < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    def self.tool_name = "get_project_pull_requests"

    def self.description
      "List pull requests for a project with optional state filter."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          github_state: { type: "string", description: "Filter by GitHub state", enum: %w[open closed] },
          limit: { type: "integer", description: "Max results (default 20)", default: 20 }
        },
        required: [ "project_id" ]
      }
    end

    def perform(project_id:, github_state: nil, limit: 20)
      project = project_for(project_id)

      prs = project.issues.pull_requests_only
      prs = prs.where(github_state:) if github_state.present?
      prs = prs.order(updated_at: :desc).limit(limit.to_i.clamp(1, 100))

      prs.map do |pr|
        {
          id: pr.id,
          github_number: pr.github_number,
          title: pr.title,
          github_state: pr.github_state,
          paid_state: pr.paid_state,
          pull_request_url: pr.github_url,
          updated_at: pr.updated_at
        }
      end
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
