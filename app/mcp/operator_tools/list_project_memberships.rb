# frozen_string_literal: true

module OperatorTools
  class ListProjectMemberships < ResourceListTool
    authorize :index?, ->(_args) { ProjectMembership.new }, policy_class: OperatorConsole::ProjectMembershipPolicy

    def self.tool_name = "operator_list_project_memberships"
    def self.model_class = ProjectMembership
    def self.policy_class = OperatorConsole::ProjectMembershipPolicy
    def self.resource_label = "project membership"
    def self.attributes = %i[id project_id user_id role created_at updated_at]
    def self.order_clause = { updated_at: :desc }
  end
end
