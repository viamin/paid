# frozen_string_literal: true

module Tools
  class GetProjectDelegation < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

    def self.tool_name = "get_project_delegation"

    def self.description
      "Get a project's delegation projection: bounded delivery authorizations currently in force, " \
        "the effective policy for each delegated phase, and the shared policy signature. " \
        "Scope to one work item with issue_id."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          issue_id: { type: "integer", description: "Optional work item ID to scope the projection" }
        },
        required: [ "project_id" ]
      }
    end

    # The shared read model (RDR-080 surface parity): the same projection the
    # settings page, Inbox, and API consume. Clients never infer authority
    # from labels, approvals, or queue state.
    # @spec PROJECT-DELEGATION-005
    def perform(project_id:, issue_id: nil)
      project = project_for(project_id)
      work_item = project.issues.find(issue_id) if issue_id

      if work_item
        ProjectDelegation::Projection.for_work_item(project: project, work_item: work_item).to_h
      else
        ProjectDelegation::Projection.for_project(project).to_h
      end
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id).tap do |project|
        raise ActiveRecord::RecordNotFound unless FeatureFlags.enabled?(:project_delegation, project:)
      end
    end
  end
end
