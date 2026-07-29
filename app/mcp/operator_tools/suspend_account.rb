# frozen_string_literal: true

module OperatorTools
  class SuspendAccount < AccountActionTool
    def self.tool_name = "operator_suspend_account"
    def self.description = "Suspend an account through the operator console workflow."
    def self.action_class = Avo::Actions::SuspendAccount
  end
end
