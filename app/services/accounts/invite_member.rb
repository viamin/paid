# frozen_string_literal: true

module Accounts
  class InviteMember
    def self.call(...)
      new(...).call
    end

    def initialize(account:, actor:, email:, role:, name: nil)
      @account = account
      @actor = actor
      @email = email.to_s.strip.downcase
      @role = role.to_s
      @name = name.to_s.strip.presence
    end

    def call
      raise AdministrationError, "Email is required." if email.blank?
      raise AdministrationError, "Role is invalid." unless AccountMembership.roles.key?(role)
      raise AdministrationError, "Use ownership transfer to assign the owner role." if role == "owner"

      existing_user = TenantContext.with_system_access do
        User.find_by(email: email)
      end
      raise AdministrationError, "That email is already used by another account." if existing_user.present? && existing_user.account_id != account.id

      membership = nil
      user = nil

      ActiveRecord::Base.transaction do
        user = existing_user || create_user!
        membership = account.account_memberships.find_or_initialize_by(user: user)
        raise AdministrationError, "That user is already a member of this account." if membership.persisted?

        membership.role = role
        membership.save!

        Accounts::RecordActivity.call(
          account: account,
          actor: actor,
          action: "membership.invited",
          subject: membership,
          metadata: { email: user.email, role: membership.role }
        )
      end

      user.send_reset_password_instructions if existing_user.nil?

      membership
    end

    private

    attr_reader :account, :actor, :email, :role, :name

    def create_user!
      password = SecureRandom.base58(24)

      account.users.create!(
        email: email,
        name: name,
        password: password,
        password_confirmation: password
      )
    end
  end
end
