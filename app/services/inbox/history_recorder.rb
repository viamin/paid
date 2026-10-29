# frozen_string_literal: true

module Inbox
  # Records only Paid-owned transitions. GitHub observations remain attributed
  # to GitHub when a scanner supplies durable evidence; this never invents one
  # from current labels or state.
  class HistoryRecorder
    def self.call(...) = new(...).call

    def initialize(entry:, event_key:, action:, actor:, result:, occurred_at: Time.current, revision: nil, evidence_url: nil)
      @entry, @event_key, @action, @actor, @result, @occurred_at, @revision, @evidence_url = entry, event_key, action, actor, result, occurred_at, revision, evidence_url
    end

    def call
      subject_key = ActionHistory.subject_key_for(entry)
      return unless subject_key && entry.project

      InboxHistoryEvent.find_or_create_by!(account: entry.project.account, project: entry.project, subject_key:, event_key:) do |event|
        event.assign_attributes(actor_label: actor.email, source: "paid", result:, occurred_at:, revision:, evidence_url:, metadata: { action: })
      end
    end

    private

    attr_reader :action, :actor, :entry, :event_key, :evidence_url, :occurred_at, :result, :revision
  end
end
