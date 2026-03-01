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
  # The allowlist is sourced from (in priority order):
  # 1. SERVICE_CONTAINER_ALLOWED_IMAGES env var (comma-separated)
  # 2. allowed_service_images from account admin/owner UserSettings
  #
  # The settings fallback is scoped to admin/owner roles to prevent
  # non-admin users from expanding the effective allowlist.
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

  # Restricts the fallback allowlist to settings from account admins/owners
  # to prevent non-admin users from expanding the effective allowlist.
  def allowed_images_from_settings
    admin_user_ids = AccountMembership.where(role: [ :admin, :owner ]).select(:user_id)

    UserSetting.where(user_id: admin_user_ids)
      .pluck(:allowed_service_images)
      .compact
      .flatten
      .uniq
  end
end
