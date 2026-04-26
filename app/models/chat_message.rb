# frozen_string_literal: true

class ChatMessage < ApplicationRecord
  ROLES = %w[system user assistant tool].freeze

  before_validation :set_external_id, on: :create

  belongs_to :chat_session

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true, unless: :tool_result_message?
  validates :external_id, uniqueness: true

  scope :chronological, -> { order(created_at: :asc) }
  scope :for_conversation, -> { where(role: %w[user assistant tool]).chronological }

  private

  def tool_result_message?
    role == "tool"
  end

  def set_external_id
    self.external_id ||= SecureRandom.uuid
  end
end
