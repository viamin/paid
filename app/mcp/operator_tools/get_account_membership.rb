# frozen_string_literal: true

module OperatorTools
  class GetAccountMembership < ResourceGetTool
    authorize :show?, ->(args) { AccountMembership.find(args.fetch(:id)) }, policy_class: OperatorConsole::AccountMembershipPolicy

    def self.tool_name = "operator_get_account_membership"
    def self.model_class = AccountMembership
    def self.policy_class = OperatorConsole::AccountMembershipPolicy
    def self.resource_label = "account membership"
    def self.attributes = %i[id account_id user_id role created_at updated_at]
  end
end
