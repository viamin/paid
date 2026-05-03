# frozen_string_literal: true

class ChatSessionProject < ApplicationRecord
  CONTEXT_TYPES = %w[primary reference].freeze

  belongs_to :chat_session, touch: true
  belongs_to :project

  validates :context_type, inclusion: { in: CONTEXT_TYPES }
  validates :project_id, uniqueness: { scope: :chat_session_id }
end
