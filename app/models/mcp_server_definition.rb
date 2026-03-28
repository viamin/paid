# frozen_string_literal: true

class McpServerDefinition < ApplicationRecord
  TRANSPORTS = %w[stdio sse].freeze
  INSTALL_TYPES = %w[npx docker_image].freeze

  belongs_to :account

  has_many :project_mcp_servers, dependent: :destroy
  has_many :projects, through: :project_mcp_servers

  validates :name, presence: true, uniqueness: { scope: :account_id }
  validates :transport, presence: true, inclusion: { in: TRANSPORTS }
  validates :install_type, presence: true, inclusion: { in: INSTALL_TYPES }
  validates :command, length: { maximum: 500 }
  validates :url, length: { maximum: 2048 }
  validates :image, length: { maximum: 500 }
  validate :npx_requires_command
  validate :npx_forbids_image
  validate :docker_image_requires_image
  validate :sse_requires_url

  scope :enabled, -> { where(enabled: true) }

  def to_snapshot
    {
      "name" => name,
      "transport" => transport,
      "install_type" => install_type,
      "command" => command,
      "args" => args,
      "url" => url,
      "image" => image,
      "env" => env,
      "metadata" => metadata
    }.compact_blank
  end

  private

  def npx_requires_command
    return unless install_type == "npx"
    return if command.present?

    errors.add(:command, "is required for npx install type")
  end

  def npx_forbids_image
    return unless install_type == "npx"
    return if image.blank?

    errors.add(:image, "is not allowed for npx install type")
  end

  def docker_image_requires_image
    return unless install_type == "docker_image"
    return if image.present?

    errors.add(:image, "is required for docker_image install type")
  end

  def sse_requires_url
    return unless transport == "sse"
    return if url.present?

    errors.add(:url, "is required for sse transport")
  end
end
