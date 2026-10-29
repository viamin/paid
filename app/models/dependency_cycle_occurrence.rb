# frozen_string_literal: true

# A durable, account-scoped operator occurrence for one effective dependency
# graph strongly connected component. Its identity is the member set, while
# details are refreshed as declarations synchronize.
class DependencyCycleOccurrence < ApplicationRecord
  belongs_to :account

  validates :cycle_key, presence: true, uniqueness: { scope: :account_id }
  validates :last_detected_at, presence: true

  scope :active, -> { where(active: true) }
end
