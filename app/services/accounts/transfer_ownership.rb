# frozen_string_literal: true

module Accounts
  class TransferOwnership
    def self.call(...)
      new(...).call
    end

    def initialize(account:, new_owner_membership:, actor:)
      @account = account
      @new_owner_membership = new_owner_membership
      @actor = actor
    end

    def call
      current_owner = account.account_memberships.find_by!(user: actor)

      raise AdministrationError, "Only an owner can transfer ownership." unless current_owner.owner?
      raise AdministrationError, "Membership does not belong to this account." unless new_owner_membership.account_id == account.id
      raise AdministrationError, "Select a different member." if new_owner_membership.user_id == actor.id

      ActiveRecord::Base.transaction do
        account.account_memberships.where(role: :owner).find_each do |membership|
          membership.update!(role: :admin)
        end

        new_owner_membership.update!(role: :owner)

        Accounts::RecordActivity.call(
          account: account,
          actor: actor,
          action: "ownership.transferred",
          subject: new_owner_membership,
          metadata: {
            from_email: actor.email,
            to_email: new_owner_membership.user.email
          }
        )
      end
    end

    private

    attr_reader :account, :new_owner_membership, :actor
  end
end
