# frozen_string_literal: true

# Explicit Paid-to-provider identity mapping (e.g. Paid user -> Linear user)
# used for trust admission and for attributing provider-authored comments.
#
# @spec UNIFIED-WORK-ITEMS-004
class ProviderIdentityMapping < ApplicationRecord
  belongs_to :account
  belongs_to :user
  belongs_to :created_by, class_name: "User", optional: true

  validates :provider, :external_id, presence: true
  validates :user_id, uniqueness: { scope: %i[account_id provider] }
  validates :external_id, uniqueness: { scope: %i[account_id provider] }
  validate :user_belongs_to_same_account

  class << self
    def user_for(account:, provider:, external_id:)
      find_by(account:, provider:, external_id:)&.user
    end

    def identity_for(account:, provider:, user:)
      find_by(account:, provider:, user:)
    end
  end

  private

  def user_belongs_to_same_account
    return if user.nil? || user.account_id == account_id

    errors.add(:user, "must belong to the same account")
  end
end
