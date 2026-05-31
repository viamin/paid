# frozen_string_literal: true

module Tools
  class InviteAccountMember < BaseTool
    authorize :update?, ->(_args) { account }, policy_class: AccountPolicy

    def self.tool_name = "invite_account_member"
    def self.write_operation? = true

    def self.description
      "Invite a user to the current account."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          email: { type: "string" },
          name: { type: "string" },
          role: { type: "string", enum: AccountMembership.roles.keys },
          confirmed: { type: "boolean" }
        },
        required: %w[email role confirmed]
      }
    end

    def self.available_to?(user:)
      policy_allows?(user:, record: user&.account, query: :update?, policy_class: AccountPolicy)
    end

    def perform(email:, role:, confirmed:, name: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to invite a member" unless confirmed

      membership = Accounts::InviteMember.call(
        account: account,
        actor: current_user,
        email:,
        name:,
        role:
      )

      {
        id: membership.id,
        user_id: membership.user_id,
        email: membership.user.email,
        name: membership.user.name,
        role: membership.role
      }
    end
  end
end
