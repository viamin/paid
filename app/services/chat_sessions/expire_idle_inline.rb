# frozen_string_literal: true

module ChatSessions
  # Expires an inline chat while retaining an untouched conversation in history.
  class ExpireIdleInline
    def self.call(chat_session:)
      chat_session.with_lock do
        return chat_session unless chat_session.active? && chat_session.idle_timeout_at&.<(Time.current)

        if chat_session.messages.where(role: "user").exists?
          ChatSessions::Close.call(chat_session: chat_session)
        else
          chat_session.update!(status: "closed", closed_at: Time.current, idle_timeout_at: nil)
        end
      end

      chat_session
    end
  end
end
