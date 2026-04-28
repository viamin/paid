# frozen_string_literal: true

module Tools
  class GetProjectIssues < BaseTool
    def self.tool_name = "get_project_issues"

    def self.description
      "List issues for a project with optional status and priority filters."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          state: { type: "string", description: "Filter by paid state", enum: Issue::PAID_STATES },
          is_pull_request: { type: "boolean", description: "Filter issues vs PRs (default: false)" },
          limit: { type: "integer", description: "Max results (default 20)", default: 20 }
        },
        required: [ "project_id" ]
      }
    end

    def call(project_id:, state: nil, is_pull_request: false, limit: 20)
      project = policy_scope(Project).find(project_id)
      authorize project, :show?

      issues = is_pull_request ? project.issues.pull_requests_only : project.issues.issues_only
      issues = issues.by_paid_state(state) if state.present?
      issues = issues.order(updated_at: :desc).limit([ limit.to_i, 100 ].min)

      issues.map do |issue|
        {
          id: issue.id,
          github_number: issue.github_number,
          title: issue.title,
          paid_state: issue.paid_state,
          github_state: issue.github_state,
          updated_at: issue.updated_at
        }
      end
    end
  end
end
