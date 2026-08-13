# frozen_string_literal: true

module Tools
  class ListProjects < BaseTool
    authorize :index?, ->(_args) { Project.new(account: account) }, policy_class: ProjectPolicy

    def self.tool_name = "list_projects"

    def self.description
      "List the user's accessible projects with their current status, repo info, and recent activity."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          status: { type: "string", description: "Filter by active/inactive status", enum: %w[active inactive] },
          limit: { type: "integer", description: "Max results (default 20)", default: 20 }
        }
      }
    end

    VALID_STATUSES = %w[active inactive].freeze

    def perform(status: nil, limit: 20)
      if status.present? && !VALID_STATUSES.include?(status)
        raise ArgumentError, "Invalid status filter '#{status}': must be 'active' or 'inactive'"
      end

      projects = policy_scope(Project)
      projects = projects.where(active: status == "active") if status.present?
      projects = projects.order(updated_at: :desc).limit(limit.to_i.clamp(1, 100))

      projects.map do |project|
        {
          id: project.id,
          name: project.name,
          repo: project.full_name,
          active: project.active,
          updated_at: project.updated_at
        }
      end
    end
  end
end
