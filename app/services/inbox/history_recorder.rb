# frozen_string_literal: true

module Inbox
  # Records only Paid-owned transitions. GitHub observations remain attributed
  # to GitHub when a scanner supplies durable evidence; this never invents one
  # from current labels or state.
  class HistoryRecorder
    def self.call(...) = new(...).call

    def initialize(entry:, event_key:, action:, actor:, result:, occurred_at: Time.current, revision: nil, evidence_url: nil,
      metadata: {})
      @entry, @event_key, @action, @actor, @result, @occurred_at = entry, event_key, action, actor, result, occurred_at
      @revision, @evidence_url, @metadata = revision, evidence_url, metadata
    end

    # @spec OPERATOR-INBOX-025
    def call
      subject_key = ActionHistory.subject_key_for(entry)
      return unless subject_key && entry.project

      event = InboxHistoryEvent.find_or_create_by!(account: entry.project.account, project: entry.project, subject_key:, event_key:) do |record|
        record.assign_attributes(actor_label:, source: "paid", result:, occurred_at:, revision:, evidence_url:,
          metadata: metadata.merge(action:))
      end
      ActionHistory.invalidate(entry:) if event.previously_new_record?
      event
    end

    private

    attr_reader :action, :actor, :entry, :event_key, :evidence_url, :metadata, :occurred_at, :result, :revision

    def actor_label = actor.respond_to?(:email) ? actor.email : actor
  end
end
