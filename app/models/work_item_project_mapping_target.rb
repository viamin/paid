# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-004
class WorkItemProjectMappingTarget < ApplicationRecord
  belongs_to :work_item_project_mapping
  belongs_to :project

  validates :project_id, uniqueness: { scope: :work_item_project_mapping_id }
  validate :project_belongs_to_mapping_account

  private

  def project_belongs_to_mapping_account
    return if work_item_project_mapping.nil? || project.nil?
    return if project.account_id == work_item_project_mapping.account_id

    errors.add(:project, "must belong to the same account as the mapping")
  end
end
