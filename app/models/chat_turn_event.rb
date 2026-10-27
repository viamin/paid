# frozen_string_literal: true

class ChatTurnEvent < ApplicationRecord
  include TenantScoped

  belongs_to :account
  belongs_to :chat_turn

  validates :event_type, presence: true
  validates :occurred_at, presence: true
end
