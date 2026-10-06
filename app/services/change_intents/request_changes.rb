# frozen_string_literal: true

module ChangeIntents
  # @spec CHANGE-INTENT-INBOX-001
  # Operator-driven "request changes" flow exposed from the Inbox detail
  # pane. Transitions the draft into the `requested_changes` state so the
  # entry remains visible until a follow-up chat or MCP draft overwrites it
  # and the operator re-approves. Stamps the reason text and timestamp on the
  # record itself, so the Inbox row can render what was asked without
  # fetching the issue/PR thread.
  class RequestChanges
    attr_reader :change_intent, :reason

    def initialize(change_intent:, reason:)
      @change_intent = change_intent
      @reason = reason
    end

    def self.call(...)
      new(...).call
    end

    def call
      change_intent.request_changes!(reason: reason)

      {
        id: change_intent.id,
        project_id: change_intent.project_id,
        status: change_intent.reload.status,
        title: change_intent.title,
        requested_changes_at: change_intent.requested_changes_at,
        requested_changes_reason: change_intent.requested_changes_reason
      }
    end
  end
end
