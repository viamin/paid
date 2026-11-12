# frozen_string_literal: true

module Inbox
  # Read-only projection for a stable issue/PR or feature identity. Queue list
  # construction never calls this service; it is intentionally detail-only.
  # @spec OPERATOR-INBOX-022 OPERATOR-INBOX-023
  class ActionHistory
    Event = Data.define(:id, :action, :actor, :source, :result, :occurred_at, :revision, :evidence_url)
    Result = Data.define(:events, :incomplete, :next_cursor, :processing_attempts, :inbox_returns)
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100
    CACHE_TTL = 20.seconds
    CACHE_PREFIX = "inbox/history/v1"

    def self.call(...) = new(...).call

    def initialize(entry:, user: nil, limit: DEFAULT_LIMIT, before: nil)
      @entry = entry
      @user = user
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @before = before
    end

    # @spec OPERATOR-INBOX-022 OPERATOR-INBOX-025
    def call
      return Result.new(events: [], incomplete: false, next_cursor: nil, processing_attempts: 0, inbox_returns: 0) unless subject_key

      returned = capture_return!
      candidates = if cacheable? && !returned
        Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
          ActionHistoryPage.call(entry:, subject_key:, limit:, before:)
        end
      else
        ActionHistoryPage.call(entry:, subject_key:, limit:, before:)
      end
      return result(events: [], next_cursor: nil) unless candidates

      page = candidates.first(limit + 1)
      visible = page.first(limit)
      result(events: visible, next_cursor: page[limit] ? visible.last.id : nil)
    end

    def self.subject_key_for(entry)
      return "issue:#{entry.project.id}:#{entry.issue.github_number}" if entry.issue

      "feature:#{entry.project.id}:#{entry.record.id}" if entry.record.is_a?(FeatureIntent)
    end

    def self.invalidate(entry:)
      subject_key = subject_key_for(entry)
      invalidate_subject(account_id: entry.project.account_id, subject_key:) if subject_key
    end

    def self.invalidate_subject(account_id:, subject_key:)
      Rails.cache.delete(cache_key_for(account_id:, subject_key:))
      Rails.cache.delete(summary_cache_key_for(account_id:, subject_key:))
    end

    def self.cache_key_for(account_id:, subject_key:)
      "#{CACHE_PREFIX}/#{account_id}/#{subject_key}"
    end

    def self.summary_cache_key_for(account_id:, subject_key:)
      "#{cache_key_for(account_id:, subject_key:)}/summary"
    end

    private

    attr_reader :before, :entry, :limit, :user

    def subject_key = self.class.subject_key_for(entry)

    def capture_return!
      return unless user && entry.issue

      removal = InboxRemoval.active.find_by(user:, request_key: entry.id)
      return unless removal && !removal.suppresses?(Inbox::RequestIdentity.occurrence_for(entry))

      occurrence = Digest::SHA256.hexdigest(Inbox::RequestIdentity.occurrence_for(entry))
      event = HistoryRecorder.call(entry:, event_key: "inbox-returned:#{removal.id}:#{occurrence}",
        action: "Returned to Inbox", actor: "Paid", result: "completed")
      event&.previously_new_record?
    end

    def legacy_coverage?
      entry.issue.present? &&
        (entry.issue.action_history_started_at.nil? || entry.issue.action_history_started_at > entry.issue.github_created_at)
    end

    # Counts run records, rather than start and finish timeline entries, so one
    # processing attempt cannot be counted twice.
    # @spec OPERATOR-INBOX-022
    def result(events:, next_cursor:)
      Result.new(events:, incomplete: legacy_coverage?, next_cursor:, **summary)
    end

    def summary
      return @summary if defined?(@summary)

      @summary = if cacheable?
        Rails.cache.fetch(summary_cache_key, expires_in: CACHE_TTL) { recorded_summary }
      else
        recorded_summary
      end
    end

    def recorded_summary
      return { processing_attempts: 0, inbox_returns: 0 } unless entry.issue

      {
        processing_attempts: ActionHistoryPage.runs_for(entry).distinct.count,
        inbox_returns: [ entry.issue.runner_retry_abandonment_count.to_i - 1, 0 ].max
      }
    end

    # Cache only the default read-only page. Cursor pages are infrequent and
    # keeping arbitrary cursors out of the cache bounds its size.
    def cacheable?
      before.blank? && limit == DEFAULT_LIMIT
    end

    def cache_key
      self.class.cache_key_for(account_id: entry.project.account_id, subject_key:)
    end

    def summary_cache_key
      self.class.summary_cache_key_for(account_id: entry.project.account_id, subject_key:)
    end
  end
end
