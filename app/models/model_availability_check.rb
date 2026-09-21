# frozen_string_literal: true

# Runner/account/auth-scoped availability evidence for a catalog model,
# distinct from LlmModel#active (the global catalog flag). Models::SeedKnownModels
# reapplies the global snapshot on every scheduled sync; this table is how
# Models::ReconcileAvailability records what was actually validated (or rejected)
# for a specific runner + auth context so that sync never has to guess.
#
# @spec MODEL-AVAILABILITY-001
class ModelAvailabilityCheck < ApplicationRecord
  STATUSES = %w[available unavailable].freeze
  DEFAULT_TTL = 6.hours

  belongs_to :llm_model
  belongs_to :account, optional: true

  validates :runner_key, presence: true
  validates :auth_type, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :source, presence: true
  validates :checked_at, presence: true
  validates :retry_count, numericality: { greater_than_or_equal_to: 0 }

  scope :global, -> { where(account_id: nil) }
  scope :available, -> { where(status: "available") }
  scope :unavailable, -> { where(status: "unavailable") }

  def available?
    status == "available"
  end

  def stale?(ttl = DEFAULT_TTL)
    return true if expires_at.present? && expires_at <= Time.current

    checked_at <= ttl.ago
  end
end
