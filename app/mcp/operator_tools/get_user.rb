# frozen_string_literal: true

module OperatorTools
  class GetUser < ResourceGetTool
    authorize :show?, ->(args) { User.find(args.fetch(:id)) }, policy_class: OperatorConsole::UserPolicy

    def self.tool_name = "operator_get_user"
    def self.model_class = User
    def self.policy_class = OperatorConsole::UserPolicy
    def self.resource_label = "user"
    def self.attributes = %i[id email name account_id created_at updated_at]
  end
end
