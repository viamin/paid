# frozen_string_literal: true

module OperatorTools
  class GetProjectMembership < ResourceGetTool
    authorize :show?, ->(args) { ProjectMembership.find(args.fetch(:id)) }, policy_class: OperatorConsole::ProjectMembershipPolicy

    def self.tool_name = "operator_get_project_membership"
    def self.model_class = ProjectMembership
    def self.policy_class = OperatorConsole::ProjectMembershipPolicy
    def self.resource_label = "project membership"
    def self.attributes = %i[id project_id user_id role created_at updated_at]
  end
end
