# frozen_string_literal: true

class ServiceContainer < ApplicationRecord
  STATUSES = %w[stopped starting running error].freeze

  has_many :project_service_containers, dependent: :destroy
  has_many :projects, through: :project_service_containers

  validates :image, presence: true
  validates :name, presence: true, uniqueness: true
  validates :port, presence: true, numericality: { only_integer: true, greater_than: 0, less_than: 65_536 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validate :image_in_allowlist, on: :create

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

  # Validates image against a global allowlist sourced from the
  # SERVICE_CONTAINER_ALLOWED_IMAGES env var (comma-separated).
  #
  # Falls back to UserSettings from account admins/owners when the
  # env var is not set.
  #
  # Only runs on :create — status updates (stop/start) must not
  # re-validate the image.
  def image_in_allowlist
    return if image.blank?

    allowed = allowed_images
    return if allowed.include?(image)

    errors.add(:image, "is not in the allowed service images list")
  end

  def allowed_images
    allowed_images_from_env || allowed_images_from_settings
  end

  def allowed_images_from_env
    raw = ENV["SERVICE_CONTAINER_ALLOWED_IMAGES"]
    return unless raw.present?

    raw.split(",").map(&:strip).reject(&:blank?).uniq
  end

  # Falls back to settings from account admins/owners when no env var is set.
  # Scoped to associated projects' accounts when possible to prevent
  # cross-account allowlist expansion in multi-tenant deployments.
  def allowed_images_from_settings
    admin_user_ids = if persisted? && project_service_containers.any?
      account_ids = projects.select(:account_id)
      AccountMembership
        .where(account_id: account_ids, role: [ :admin, :owner ])
        .select(:user_id)
    else
      AccountMembership
        .where(role: [ :admin, :owner ])
        .select(:user_id)
    end

    UserSetting.where(user_id: admin_user_ids)
      .pluck(:allowed_service_images)
      .compact
      .flatten
      .uniq
  end
end
