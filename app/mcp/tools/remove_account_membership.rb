# frozen_string_literal: true

module Tools
  class RemoveAccountMembership < BaseTool
    authorize :update?, ->(_args) { account }, policy_class: AccountPolicy

    def self.tool_name = "remove_account_membership"
    def self.write_operation? = true

    def self.description
      "Remove a membership from the current account."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          membership_id: { type: "integer" },
          confirmed: { type: "boolean" }
        },
        required: %w[membership_id confirmed]
      }
    end

    def self.available_to?(user:)
      policy_allows?(user:, record: user&.account, query: :update?, policy_class: AccountPolicy)
    end

    def perform(membership_id:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to remove a membership" unless confirmed

      membership = account.account_memberships.find(membership_id)
      result = {
        id: membership.id,
        user_id: membership.user_id,
        role: membership.role
      }

      Accounts::RemoveMembership.call(
        account:,
        membership:,
        actor: current_user
      )

      result
    end
  end
end
