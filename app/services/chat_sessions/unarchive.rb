# frozen_string_literal: true

module ChatSessions
  class Unarchive
    attr_reader :chat_session

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!

      ActiveRecord::Base.transaction do
        discard_conflicting_personal_draft
        chat_session.update!(restore_attributes)
      end

      chat_session
    end

    private

    def validate!
      return if chat_session.status == "archived"

      raise ArgumentError, "chat session must be archived to restore (current: #{chat_session.status})"
    end

    # @spec CHAT-API-030
    # A fresh blank draft may have been created while this one was archived.
    # Restoring an archived blank draft must not collide with the
    # one-unstarted-draft-per-user invariant, and the conflicting draft is
    # blank by definition (no user message, no title), so it is discarded.
    def discard_conflicting_personal_draft
      return unless restoring_personal_draft?

      conflicting_personal_drafts.find_each do |draft|
        ChatSessions::Close.call(chat_session: draft)
      end
    end

    def conflicting_personal_drafts
      chat_session.class.unstarted_untitled_personal
        .where(account_id: chat_session.account_id, created_by_id: chat_session.created_by_id)
        .where.not(id: chat_session.id)
    end

    def restoring_personal_draft?
      chat_session.created_by.present? && chat_session.started_at.nil? &&
        chat_session.inbox_item_key.nil? && chat_session.clarifying_question_issue_id.nil? &&
        chat_session.feature_intent_id.nil? && chat_session.title.blank?
    end

    def restore_attributes
      {
        status: "active",
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now,
        metadata: (chat_session.metadata || {}).merge("unarchived_at" => Time.current.iso8601)
      }
    end
  end
end
