# frozen_string_literal: true

class ProjectServiceContainer < ApplicationRecord
  belongs_to :project
  belongs_to :service_container

  validates :service_container_id, uniqueness: { scope: :project_id }
  validate :service_container_belongs_to_project_account

  # Association changes alter the configured verification services behind the
  # persisted readiness snapshot, so every affected project re-evaluates. The
  # job discards itself when its project no longer exists.
  # @spec PROJECT-READINESS-006
  after_commit :enqueue_project_readiness_evaluations, on: %i[ create update destroy ]

  private

  def service_container_belongs_to_project_account
    return if project.blank? || service_container.blank?
    return if project.account_id == service_container.account_id

    errors.add(:service_container, "must belong to the same account as the project")
  end

  def enqueue_project_readiness_evaluations
    affected_project_ids = destroyed? ? [ project_id ] : [ project_id_before_last_save, project_id ].compact.uniq
    affected_project_ids.each { |id| EvaluateProjectReadinessJob.perform_later(id) }
  end
end
