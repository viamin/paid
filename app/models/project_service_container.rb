# frozen_string_literal: true

class ProjectServiceContainer < ApplicationRecord
  belongs_to :project
  belongs_to :service_container

  validates :service_container_id, uniqueness: { scope: :project_id }
  validate :service_container_belongs_to_project_account

  private

  def service_container_belongs_to_project_account
    return if project.blank? || service_container.blank?
    return if project.account_id == service_container.account_id

    errors.add(:service_container, "must belong to the same account as the project")
  end
end
