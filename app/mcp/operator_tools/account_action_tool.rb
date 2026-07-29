# frozen_string_literal: true

module OperatorTools
  class AccountActionTool < BaseTool
    authorize :act_on?, ->(args) { account_for(args.fetch(:account_id)) }, policy_class: OperatorConsole::AccountPolicy

    def self.write_operation? = true

    def self.input_schema
      {
        type: "object",
        properties: {
          account_id: { type: "integer", description: "Account ID" },
          confirmed: { type: "boolean", description: "Must be true to execute this operator action" }
        },
        required: %w[account_id confirmed]
      }
    end

    def perform(account_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to execute this operator action" unless confirmed

      action = self.class.action_class.new.handle(
        query: [ account_for(account_id) ],
        fields: {},
        current_user: user,
        resource: nil
      )

      normalize_action_response(action.response, account_id:)
    end

    private

    def account_for(account_id)
      @accounts_by_id ||= {}
      @accounts_by_id[account_id] ||= operator_policy_scope(Account, policy_class: OperatorConsole::AccountPolicy).find(account_id)
    end

    def normalize_action_response(response, account_id:)
      message = Array(response[:messages]).last || {}
      {
        status: message[:type] == :success ? "ok" : "error",
        account_id: account_id,
        action: self.class.tool_name,
        message: message[:body]
      }
    end
  end
end
