# frozen_string_literal: true

# Persisted provider ticket, independent of a Paid project assignment.
class WorkItem < ApplicationRecord
  belongs_to :account
  belongs_to :tracker_configuration, optional: true

  validates :provider, :resource_type, :external_id, :title, presence: true
  validates :external_id, uniqueness: { scope: %i[account_id provider resource_type] }
  validate :tracker_configuration_belongs_to_account

  private

  def tracker_configuration_belongs_to_account
    return if tracker_configuration.nil? || tracker_configuration.account&.id == account_id

    errors.add(:tracker_configuration, "must belong to the same account")
  end
end
