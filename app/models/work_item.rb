# frozen_string_literal: true

# Persisted provider ticket, independent of a Paid project assignment.
#
# @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-006
class WorkItem < ApplicationRecord
  LIFECYCLE_SOURCES = %w[provider paid].freeze

  belongs_to :account
  belongs_to :tracker_configuration, optional: true

  has_many :work_item_assignments, dependent: :destroy
  has_many :projects, through: :work_item_assignments
  has_many :work_item_assignment_overrides, dependent: :destroy
  has_many :work_item_lifecycle_conflicts, dependent: :destroy

  validates :provider, :resource_type, :external_id, :title, presence: true
  validates :external_id, uniqueness: { scope: %i[account_id provider resource_type] }
  validates :lifecycle_sync_source, inclusion: { in: LIFECYCLE_SOURCES }, allow_nil: true
  validate :tracker_configuration_belongs_to_account

  # @spec UNIFIED-WORK-ITEMS-004
  scope :unassigned_first, lambda {
    select(
      "work_items.*",
      Arel.sql(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM work_item_assignments wia WHERE wia.work_item_id = work_items.id
        ) AS work_item_unassigned
      SQL
    ).order(Arel.sql("work_item_unassigned DESC"), created_at: :desc)
  }

  scope :needing_review, -> { where.not(assignment_review_flagged_at: nil) }
  scope :for_native_project, ->(native_project_id) { where(native_project_id:) }

  def unassigned? = work_item_assignments.empty?

  def locked_from_mapping? = work_item_assignments.exists?(locked: true)

  def flag_for_review!
    update!(assignment_review_flagged_at: Time.current)
  end

  def clear_review_flag!
    update!(assignment_review_flagged_at: nil)
  end

  def needs_review? = assignment_review_flagged_at.present?

  private

  def tracker_configuration_belongs_to_account
    return if tracker_configuration.nil? || tracker_configuration.account&.id == account_id

    errors.add(:tracker_configuration, "must belong to the same account")
  end
end
