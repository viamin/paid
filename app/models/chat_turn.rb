# frozen_string_literal: true

# Durable lifecycle for one user-initiated chat turn. The transcript remains
# the source of conversational evidence; this row makes an unfinished turn
# queryable without mistaking a missing assistant message for success.
class ChatTurn < ApplicationRecord
  LIFECYCLES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  ACTIVE_LIFECYCLES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :lifecycle, inclusion: { in: LIFECYCLES }
  validates :user_message_id, uniqueness: true
  validate :user_message_belongs_to_session

  scope :active, -> { where(lifecycle: ACTIVE_LIFECYCLES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ..time) }

  def self.start_for!(chat_session:, user_message:)
    find_by(user_message:) || create!(user_message:) do |turn|
      turn.chat_session = chat_session
      turn.lifecycle = "streaming"
      turn.last_activity_at = Time.current
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(user_message:)
  end

  def touch_activity!
    update!(last_activity_at: Time.current) if lifecycle.in?(ACTIVE_LIFECYCLES)
  end

  def complete!
    update!(lifecycle: "completed", last_activity_at: Time.current)
  end

  def await_confirmation!
    update!(lifecycle: "awaiting_confirmation", last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(lifecycle: "failed", classification:, last_activity_at: Time.current)
  end

  def stall!(classification:)
    update!(lifecycle: "stalled", classification:, detected_at: Time.current)
  end

  private

  def user_message_belongs_to_session
    return unless chat_session && user_message
    return if user_message.chat_session_id == chat_session.id

    errors.add(:user_message, "must belong to the chat session")
  end
end
