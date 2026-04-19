# frozen_string_literal: true

class TenantSetting < ApplicationRecord
  PG_INT_MAX = 2_147_483_647

  belongs_to :account

  validates :max_concurrent_runs,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }
  validates :max_projects,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :max_users,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :max_tokens_per_run,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: PG_INT_MAX }
  validates :max_monthly_cost_cents,
    numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: PG_INT_MAX },
    allow_nil: true
  validate :validate_features_is_hash

  private

  def validate_features_is_hash
    return if features.is_a?(Hash)

    errors.add(:features, "must be a JSON object")
  end
end
