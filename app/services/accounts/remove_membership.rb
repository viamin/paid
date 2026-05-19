# frozen_string_literal: true

module Accounts
  class RemoveMembership
    def self.call(...)
      new(...).call
    end

    def initialize(account:, membership:, actor:)
      @account = account
      @membership = membership
      @actor = actor
    end

    def call
      raise AdministrationError, "Membership does not belong to this account." unless membership.account_id == account.id
      raise AdministrationError, "Transfer ownership before removing an owner." if membership.owner?

      email = membership.user.email

      ActiveRecord::Base.transaction do
        membership.destroy!

        Accounts::RecordActivity.call(
          account: account,
          actor: actor,
          action: "membership.removed",
          metadata: { email: email }
        )
      end
    end

    private

    attr_reader :account, :membership, :actor
  end
end
