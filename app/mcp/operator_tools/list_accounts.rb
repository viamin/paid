# frozen_string_literal: true

module OperatorTools
  class ListAccounts < ResourceListTool
    authorize :index?, ->(_args) { Account.new }, policy_class: OperatorConsole::AccountPolicy

    def self.tool_name = "operator_list_accounts"
    def self.model_class = Account
    def self.policy_class = OperatorConsole::AccountPolicy
    def self.resource_label = "account"
    def self.attributes = %i[id name slug plan status suspended_at deactivated_at created_at updated_at]
    def self.order_clause = { updated_at: :desc }
  end
end
