# frozen_string_literal: true

# Durable lifecycle record for a user-initiated chat turn. Message rows remain
# the transcript; this row makes an incomplete exchange queryable and recoverable.
class ChatTurn < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_TIMEOUT = 10.minutes

  belongs_to :account
  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :actor, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true
  validate :chat_session_belongs_to_account

  scope :unfinished, -> { where(status: %w[pending streaming]) }
  scope :stale_before, ->(time) { unfinished.where(last_activity_at: ..time) }

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end

  def known_long_running?
    deadline = metadata["long_running_until"]
    deadline.present? && Time.zone.parse(deadline.to_s) > Time.current
  rescue ArgumentError
    false
  end

  def side_effecting_tool_completed?
    calls = chat_session.messages.where(role: "assistant").where.not(tool_name: nil).pluck(:tool_name)
    calls.any? { |tool_name| Tools::Registry.write_tool?(tool_name) }
  end

  private

  def chat_session_belongs_to_account
    return unless chat_session && account
    return if chat_session.account_id == account_id

    errors.add(:chat_session, "must belong to the turn account")
  end
end
