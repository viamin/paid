# frozen_string_literal: true

class AgentRunMarketplaceEntry < ApplicationRecord
  ATTACHMENT_SOURCES = %w[automatic team_default manual].freeze

  belongs_to :agent_run
  belongs_to :marketplace_entry
  belongs_to :marketplace_entry_version

  validates :attachment_source, presence: true, inclusion: { in: ATTACHMENT_SOURCES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :rendered_format, presence: true, length: { maximum: 100 }
  validate :rendered_payload_is_object
  validate :version_belongs_to_entry

  scope :ordered, -> { order(:position, :id) }

  private

  def rendered_payload_is_object
    errors.add(:rendered_payload, "must be an object") unless rendered_payload.is_a?(Hash)
  end

  def version_belongs_to_entry
    return if marketplace_entry_version.nil? || marketplace_entry.nil?
    return if marketplace_entry_version.marketplace_entry_id == marketplace_entry_id

    errors.add(:marketplace_entry_version, "must belong to the associated marketplace entry")
  end
end
