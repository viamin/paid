# frozen_string_literal: true

module Inbox
  # Read-only projection for a stable issue/PR or feature identity. Queue list
  # construction never calls this service; it is intentionally detail-only.
  # @spec OPERATOR-INBOX-022 OPERATOR-INBOX-023
  class ActionHistory
    Event = Data.define(:id, :action, :actor, :source, :result, :occurred_at, :revision, :evidence_url)
    Result = Data.define(:events, :incomplete, :next_cursor)
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    def self.call(...) = new(...).call

    def initialize(entry:, user: nil, limit: DEFAULT_LIMIT, before: nil)
      @entry = entry
      @user = user
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @before = before
    end

    # @spec OPERATOR-INBOX-022
    def call
      return Result.new(events: [], incomplete: false, next_cursor: nil) unless subject_key

      capture_return!
      page = events.drop_while { |event| before && event.id != before }.drop(before ? 1 : 0).first(limit + 1)
      Result.new(events: page.first(limit), incomplete: legacy_coverage?, next_cursor: page[limit]&.id)
    end

    def self.subject_key_for(entry)
      return "issue:#{entry.project.id}:#{entry.issue.github_number}" if entry.issue

      "feature:#{entry.project.id}:#{entry.record.id}" if entry.record.is_a?(FeatureIntent)
    end

    private

    attr_reader :before, :entry, :limit, :user

    def subject_key = self.class.subject_key_for(entry)

    def events
      (@events ||= persisted_events + run_events).sort_by { |event| [ -event.occurred_at.to_f, event.id ] }
    end

    def persisted_events
      InboxHistoryEvent.for_subject(account: entry.project.account, subject_key:).newest_first.map do |event|
        Event.new(id: "history:#{event.id}", action: event.metadata.fetch("action", event.event_key), actor: event.actor_label,
          source: event.source, result: event.result, occurred_at: event.occurred_at, revision: event.revision, evidence_url: event.evidence_url)
      end
    end

    def run_events
      return [] unless entry.issue

      runs = entry.project.agent_runs.where(issue: entry.issue).or(entry.project.agent_runs.where(source_pull_request_number: entry.issue.github_number))
      runs.flat_map do |run|
        [ Event.new(id: "run-start:#{run.id}", action: "Agent run started", actor: "Paid", source: "paid", result: "attempted", occurred_at: run.started_at || run.created_at, revision: run.base_commit_sha, evidence_url: run.pull_request_url),
          terminal_event(run) ].compact
      end
    end

    def terminal_event(run)
      return unless run.completed_at

      result = run.status == "completed" ? "completed" : "failed"
      Event.new(id: "run-finish:#{run.id}", action: "Agent run #{result}", actor: "Paid", source: "paid", result:, occurred_at: run.completed_at, revision: run.result_commit_sha, evidence_url: run.pull_request_url || run.review_url)
    end

    def capture_return!
      return unless user && entry.issue

      removal = InboxRemoval.active.find_by(user:, request_key: entry.id)
      return unless removal && !removal.suppresses?(Inbox::RequestIdentity.occurrence_for(entry))

      occurrence = Digest::SHA256.hexdigest(Inbox::RequestIdentity.occurrence_for(entry))
      HistoryRecorder.call(entry:, event_key: "inbox-returned:#{removal.id}:#{occurrence}",
        action: "Returned to Inbox", actor: user, result: "completed")
      @events = nil
    end

    def legacy_coverage?
      entry.issue.present? && persisted_events.empty? && run_events.empty?
    end
  end
end
