# frozen_string_literal: true

class ServiceContainer < ApplicationRecord
  STATUSES = %w[stopped starting running error].freeze

  has_many :project_service_containers, dependent: :destroy
  has_many :projects, through: :project_service_containers

  validates :image, presence: true
  validates :name, presence: true, uniqueness: true
  validates :port, presence: true, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :image_in_allowlist

  scope :running, -> { where(status: "running") }
  scope :stopped, -> { where(status: "stopped") }

  def running?
    status == "running"
  end

  # Counts active agent runs across all associated projects that reference this container.
  def active_agent_run_count
    AgentRun.active
      .where(project_id: project_ids)
      .where("service_container_ids @> ?", [ id ].to_json)
      .count
  end

  private

  # Validates image against the union of all users' allowed_service_images.
  #
  # This is a global union because ServiceContainer is a shared resource
  # without a direct user/account association. Any user who adds an image
  # to their settings expands the effective allowlist for all users.
  # This is acceptable for single-tenant deployments. For multi-tenant,
  # scope to the account level or use an admin-only setting.
  # TODO(#216): Scope allowlist to account when multi-tenancy is added.
  def image_in_allowlist
    return if image.blank?

    allowed = UserSetting.pluck(:allowed_service_images)
      .compact
      .flatten
      .uniq

    return if allowed.include?(image)

    errors.add(:image, "is not in the allowed service images list")
  end
end
