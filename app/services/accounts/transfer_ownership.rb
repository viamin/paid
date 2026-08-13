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
      TenantContext.with_system_access do
        current_owner = account.account_memberships.find_by!(user: actor)
        target_membership = account.account_memberships.includes(:user).find(new_owner_membership.id)
        new_owner = target_membership.user

        raise AdministrationError, "Only an owner can transfer ownership." unless current_owner.owner?
        raise AdministrationError, "Membership does not belong to this account." unless target_membership.account_id == account.id
        raise AdministrationError, "Select a different member." if target_membership.user_id == actor.id

        ActiveRecord::Base.transaction do
          account.account_memberships.where(role: :owner).find_each do |membership|
            membership.update!(role: :admin)
          end

          target_membership.update!(role: :owner)
          new_owner.update!(account: account) if new_owner.account_id != account.id

          Accounts::RecordActivity.call(
            account: account,
            actor: actor,
            action: "ownership.transferred",
            subject: target_membership,
            metadata: {
              from_email: actor.email,
              to_email: target_membership.user.email
            }
          )
        end
      end
    end

    private

    attr_reader :account, :new_owner_membership, :actor
  end
end
