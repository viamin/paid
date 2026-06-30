# frozen_string_literal: true

class ChatMessage < ApplicationRecord
  ROLES = %w[system user assistant tool].freeze
  TOOL_STATUSES = %w[pending approved denied].freeze

  before_validation :set_external_id, on: :create

  belongs_to :chat_session

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true, unless: -> { tool_result_message? || tool_name.present? }
  validates :tool_status, inclusion: { in: TOOL_STATUSES }, allow_nil: true
  validates :external_id, uniqueness: true

  scope :chronological, -> { order(created_at: :asc) }
  scope :for_conversation, -> { where(role: %w[user assistant tool]).chronological }
  scope :pending_tool_confirmations, -> { where.not(tool_status: nil).where(tool_status: "pending") }

  def pending_confirmation?
    tool_status == "pending"
  end

  def resolved_tool_confirmation?
    tool_status == "approved" || tool_status == "denied"
  end

  # A server-injected assistant message announcing a runner fallback (rate
  # limit / provider error). Excluded from the LLM conversation rebuild and
  # surfaced to clients via a dedicated event flag.
  def fallback_notice?
    metadata.is_a?(Hash) && metadata["fallback_notice"] == true
  end

  private

  def tool_result_message?
    role == "tool"
  end

  def set_external_id
    self.external_id ||= SecureRandom.uuid
  end
end
