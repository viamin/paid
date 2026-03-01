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

  # Validates image against a global, admin-controlled allowlist.
  #
  # The allowlist is configured via the SERVICE_CONTAINER_ALLOWED_IMAGES
  # environment variable (comma-separated list of allowed image names).
  # Falls back to per-user settings if the env var is not set.
  # This avoids deriving the allowlist solely from per-user settings,
  # which could let one user expand the effective allowlist for all
  # users in a multi-tenant deployment.
  def image_in_allowlist
    return if image.blank?

    allowed = allowed_images_from_env || allowed_images_from_settings
    return if allowed.include?(image)

    errors.add(:image, "is not in the allowed service images list")
  end

  def allowed_images_from_env
    raw = ENV["SERVICE_CONTAINER_ALLOWED_IMAGES"]
    return unless raw.present?

    raw.split(",").map(&:strip).reject(&:blank?).uniq
  end

  def allowed_images_from_settings
    UserSetting.pluck(:allowed_service_images)
      .compact
      .flatten
      .uniq
  end
end
