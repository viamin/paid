# frozen_string_literal: true

# Durable lifecycle and recovery evidence for one interactive chat request.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true
  validates :user_message_id, uniqueness: true

  scope :detectable, -> { where(status: %w[pending streaming]) }
  scope :stalled, -> { where(status: "stalled") }

  def self.start_for!(chat_session:, user_message:, stream_message_id:)
    create!(chat_session:, user_message:, stream_message_id:, activity_at: Time.current)
  rescue ActiveRecord::RecordNotUnique
    find_by!(stream_message_id:)
  end

  def streaming!
    update!(status: "streaming", activity_at: Time.current)
  end

  def completed!
    update!(status: "completed", activity_at: Time.current)
  end

  def failed!(classification:)
    update!(status: "failed", activity_at: Time.current, metadata: metadata.merge("failure_classification" => classification))
  end

  def stalled!(classification:)
    update!(status: "stalled", detection_at: Time.current, metadata: metadata.merge("stall_classification" => classification))
  end

  def awaiting_confirmation?
    chat_session.messages.pending_tool_confirmations.where("id > ?", user_message_id).exists?
  end

  def rate_limited?
    chat_session.rate_limited_until.present? && chat_session.rate_limited_until.future?
  end

  STATUSES.each do |value|
    define_method("#{value}?") { status == value }
  end
end
