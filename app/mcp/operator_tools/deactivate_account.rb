# frozen_string_literal: true

module OperatorTools
  class DeactivateAccount < AccountActionTool
    def self.tool_name = "operator_deactivate_account"
    def self.description = "Deactivate an account through the operator console workflow."
    def self.action_class = Avo::Actions::DeactivateAccount
  end
end
