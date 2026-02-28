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

  def image_in_allowlist
    return if image.blank?

    allowed = UserSetting.pick(:allowed_service_images)
    return if allowed.nil? # No user settings configured yet
    return if allowed.include?(image)

    errors.add(:image, "is not in the allowed service images list")
  end
end
