# frozen_string_literal: true

# A durable execution record for one user-initiated chat turn. Transcript rows
# remain the evidence; this record makes an unfinished execution observable.
class ChatTurn < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :account
  belongs_to :initiating_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :initiating_message_id, uniqueness: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, ->(time) { active.where(activity_at: ...time) }

  def touch_activity!
    update!(activity_at: Time.current) if active?
  end

  def active?
    status.in?(ACTIVE_STATUSES)
  end

  def awaiting_confirmation?
    status == "awaiting_confirmation"
  end
end
