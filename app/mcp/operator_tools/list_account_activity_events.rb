# frozen_string_literal: true

module OperatorTools
  class ListAccountActivityEvents < ResourceListTool
    authorize :index?, ->(_args) { AccountActivityEvent.new }, policy_class: OperatorConsole::AccountActivityEventPolicy

    def self.tool_name = "operator_list_account_activity_events"
    def self.model_class = AccountActivityEvent
    def self.policy_class = OperatorConsole::AccountActivityEventPolicy
    def self.resource_label = "account activity event"
    def self.attributes = %i[id account_id action actor_id subject_type subject_id metadata created_at updated_at]
    def self.order_clause = { created_at: :desc }
  end
end
