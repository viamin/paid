# frozen_string_literal: true

# A provider-native project (e.g. a Linear project) mapped to one or more
# repository-backed Paid projects, with a bulk-assignment mode.
#
# @spec UNIFIED-WORK-ITEMS-004
class WorkItemProjectMapping < ApplicationRecord
  ASSIGNMENT_MODES = %w[current_and_future future_only none].freeze

  belongs_to :account
  belongs_to :tracker_configuration, optional: true
  belongs_to :default_execution_project, class_name: "Project", optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :work_item_project_mapping_targets, dependent: :destroy
  has_many :projects, through: :work_item_project_mapping_targets

  validates :provider, :native_project_id, presence: true
  validates :native_project_id, uniqueness: { scope: %i[account_id provider] }
  validates :assignment_mode, inclusion: { in: ASSIGNMENT_MODES }
  validate :default_execution_project_is_a_target
  validate :target_projects_belong_to_same_account

  def current_and_future? = assignment_mode == "current_and_future"
  def future_only? = assignment_mode == "future_only"
  def no_auto_assignment? = assignment_mode == "none"

  private

  def default_execution_project_is_a_target
    return if default_execution_project_id.blank?
    return if work_item_project_mapping_targets.exists?(project_id: default_execution_project_id)

    errors.add(:default_execution_project, "must be one of this mapping's target projects")
  end

  def target_projects_belong_to_same_account
    return if projects.all? { |project| project.account_id == account_id }

    errors.add(:projects, "must belong to the same account as the mapping")
  end
end
