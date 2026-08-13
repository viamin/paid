# frozen_string_literal: true

module OperatorTools
  class ListAccountMemberships < ResourceListTool
    authorize :index?, ->(_args) { AccountMembership.new }, policy_class: OperatorConsole::AccountMembershipPolicy

    def self.tool_name = "operator_list_account_memberships"
    def self.model_class = AccountMembership
    def self.policy_class = OperatorConsole::AccountMembershipPolicy
    def self.resource_label = "account membership"
    def self.attributes = %i[id account_id user_id role created_at updated_at]
    def self.order_clause = { updated_at: :desc }
  end
end
