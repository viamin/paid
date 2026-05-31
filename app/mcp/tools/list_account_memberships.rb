# frozen_string_literal: true

module Tools
  class ListAccountMemberships < BaseTool
    authorize :show?, ->(_args) { account }, policy_class: AccountPolicy

    def self.tool_name = "list_account_memberships"

    def self.description
      "List memberships for the current account."
    end

    def self.available_to?(user:)
      policy_allows?(user:, record: user&.account, query: :show?, policy_class: AccountPolicy)
    end

    def perform
      account.account_memberships.includes(:user).order(role: :desc, created_at: :asc).map do |membership|
        {
          id: membership.id,
          user_id: membership.user_id,
          email: membership.user.email,
          name: membership.user.name,
          role: membership.role,
          created_at: membership.created_at
        }
      end
    end
  end
end
