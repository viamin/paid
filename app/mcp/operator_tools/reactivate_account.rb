# frozen_string_literal: true

module OperatorTools
  class ReactivateAccount < AccountActionTool
    def self.tool_name = "operator_reactivate_account"
    def self.description = "Reactivate an account through the operator console workflow."
    def self.action_class = Avo::Actions::ReactivateAccount
  end
end
