# frozen_string_literal: true

module Accounts
  class UpdateMembership
    def self.call(...)
      new(...).call
    end

    def initialize(account:, membership:, actor:, role:)
      @account = account
      @membership = membership
      @actor = actor
      @role = role.to_s
    end

    def call
      raise AdministrationError, "Membership does not belong to this account." unless membership.account_id == account.id
      raise AdministrationError, "Role is invalid." unless AccountMembership.roles.key?(role)
      raise AdministrationError, "Use ownership transfer to assign the owner role." if role == "owner"
      raise AdministrationError, "Use ownership transfer to change the current owner." if membership.owner?

      previous_role = membership.role
      return membership if previous_role == role

      membership.update!(role: role)

      Accounts::RecordActivity.call(
        account: account,
        actor: actor,
        action: "membership.role_changed",
        subject: membership,
        metadata: {
          email: membership.user.email,
          from_role: previous_role,
          to_role: membership.role
        }
      )

      membership
    end

    private

    attr_reader :account, :membership, :actor, :role
  end
end
