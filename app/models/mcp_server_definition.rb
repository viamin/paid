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
  validate :args_json_valid
  validate :env_json_valid
  validate :metadata_json_valid

  scope :enabled, -> { where(enabled: true) }

  # Virtual attributes for editing jsonb fields as JSON text in forms
  def args_json
    (args || []).to_json
  end

  def args_json=(value)
    self.args = value.present? ? JSON.parse(value) : []
  rescue JSON::ParserError
    @args_json_invalid = true
  end

  def env_json
    (env || {}).to_json
  end

  def env_json=(value)
    self.env = value.present? ? JSON.parse(value) : {}
  rescue JSON::ParserError
    @env_json_invalid = true
  end

  def metadata_json
    (metadata || {}).to_json
  end

  def metadata_json=(value)
    self.metadata = value.present? ? JSON.parse(value) : {}
  rescue JSON::ParserError
    @metadata_json_invalid = true
  end

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

  def args_json_valid
    errors.add(:args_json, "must be valid JSON") if @args_json_invalid
  end

  def env_json_valid
    errors.add(:env_json, "must be valid JSON") if @env_json_invalid
  end

  def metadata_json_valid
    errors.add(:metadata_json, "must be valid JSON") if @metadata_json_invalid
  end
end
