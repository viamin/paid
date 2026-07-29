# frozen_string_literal: true

module OperatorTools
  class GetAccountActivityEvent < ResourceGetTool
    authorize :show?, ->(args) { AccountActivityEvent.find(args.fetch(:id)) }, policy_class: OperatorConsole::AccountActivityEventPolicy

    def self.tool_name = "operator_get_account_activity_event"
    def self.model_class = AccountActivityEvent
    def self.policy_class = OperatorConsole::AccountActivityEventPolicy
    def self.resource_label = "account activity event"
    def self.attributes = %i[id account_id action actor_id subject_type subject_id metadata created_at updated_at]
  end
end
