# frozen_string_literal: true

# A simultaneous conflicting lifecycle change (a provider-native state and a
# Paid state changed independently before either side observed the other's
# write) surfaced for human review instead of being silently resolved.
#
# @spec UNIFIED-WORK-ITEMS-006
class WorkItemLifecycleConflict < ApplicationRecord
  belongs_to :account
  belongs_to :work_item
  belongs_to :resolved_by, class_name: "User", optional: true

  validates :detected_at, presence: true

  scope :unresolved, -> { where(resolved_at: nil) }

  def resolved? = resolved_at.present?

  def resolve!(resolution:, user: nil)
    update!(resolved_at: Time.current, resolution:, resolved_by: user)
  end
end
