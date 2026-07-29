# frozen_string_literal: true

module OperatorTools
  class ListUsers < ResourceListTool
    authorize :index?, ->(_args) { User.new }, policy_class: OperatorConsole::UserPolicy

    def self.tool_name = "operator_list_users"
    def self.model_class = User
    def self.policy_class = OperatorConsole::UserPolicy
    def self.resource_label = "user"
    def self.attributes = %i[id email name account_id created_at updated_at]
    def self.order_clause = { updated_at: :desc }
  end
end
