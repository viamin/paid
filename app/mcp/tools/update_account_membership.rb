# frozen_string_literal: true

module Tools
  class UpdateAccountMembership < BaseTool
    authorize :update?, ->(_args) { account }, policy_class: AccountPolicy

    def self.tool_name = "update_account_membership"
    def self.write_operation? = true

    def self.description
      "Update a membership role in the current account."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          membership_id: { type: "integer" },
          role: { type: "string", enum: AccountMembership.roles.keys },
          confirmed: { type: "boolean" }
        },
        required: %w[membership_id role confirmed]
      }
    end

    def self.available_to?(user:)
      policy_allows?(user:, record: user&.account, query: :update?, policy_class: AccountPolicy)
    end

    def perform(membership_id:, role:, confirmed:)
      raise ArgumentError, "Confirmation required: set confirmed=true to update a membership" unless confirmed

      membership = account.account_memberships.includes(:user).find(membership_id)

      Accounts::UpdateMembership.call(
        account:,
        membership:,
        actor: current_user,
        role:
      )

      {
        id: membership.id,
        user_id: membership.user_id,
        email: membership.user.email,
        name: membership.user.name,
        role: membership.reload.role
      }
    end
  end
end
