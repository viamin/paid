# frozen_string_literal: true

module OperatorTools
  class GetAccount < ResourceGetTool
    authorize :show?, ->(args) { Account.find(args.fetch(:id)) }, policy_class: OperatorConsole::AccountPolicy

    def self.tool_name = "operator_get_account"
    def self.model_class = Account
    def self.policy_class = OperatorConsole::AccountPolicy
    def self.resource_label = "account"
    def self.attributes = %i[
      id name slug plan status default_max_tokens_per_run trial_ends_at onboarding_completed_at
      scheduler_paused_at suspended_at deactivated_at created_at updated_at
    ]
  end
end
