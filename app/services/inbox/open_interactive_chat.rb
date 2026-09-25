# frozen_string_literal: true

module Inbox
  # @spec QUESTION-EXPLORATION-001 @spec QUESTION-EXPLORATION-014
  class OpenInteractiveChat
    def self.call(...)
      new(...).call
    end

    def initialize(user:, entry:)
      @user = user
      @entry = entry
    end

    def call
      authorize!
      active_chat || create_chat
    rescue ActiveRecord::RecordNotUnique
      active_chat || raise
    end

    private

    attr_reader :entry, :user

    def authorize!
      raise Pundit::NotAuthorizedError unless authoritative_entry
      raise Pundit::NotAuthorizedError unless InteractiveChatAccess.allowed?(user:, project:)
    end

    def authoritative_entry
      @authoritative_entry ||= Inbox::Queue.call(user:).find { |candidate| candidate.id == entry.id }
    end

    def active_chat
      ChatSession.active.find_by(created_by: user, inbox_item_key: authoritative_entry.id)
    end

    def create_chat
      ChatSessions::Create.call(
        account: user.account,
        user:,
        project_id: project.id,
        title: authoritative_entry.title,
        metadata: { "inbox_item" => audit_metadata },
        inbox_item_key: authoritative_entry.id,
        inbox_item_metadata: audit_metadata,
        opened_at: Time.current
      )
    end

    def project
      authoritative_entry.project
    end

    def audit_metadata
      {
        "kind" => authoritative_entry.kind,
        "issue_id" => authoritative_entry.issue&.id,
        "record_id" => authoritative_entry.record&.id,
        "record_type" => authoritative_entry.record&.class&.name,
        "waiting_since" => authoritative_entry.waiting_since&.iso8601
      }.compact
    end
  end
end
