# frozen_string_literal: true

module Inbox
  # Read-only projection for a stable issue/PR or feature identity. Queue list
  # construction never calls this service; it is intentionally detail-only.
  # @spec OPERATOR-INBOX-022 OPERATOR-INBOX-023 OPERATOR-INBOX-028
  class ActionHistory
    Event = Data.define(:id, :action, :actor, :source, :result, :occurred_at, :revision, :evidence_url)
    Summary = Data.define(:processing_attempts, :inbox_returns, :retry_limits, :token_budget_exceeded)
    Result = Data.define(:events, :incomplete, :next_cursor, :summary)
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100
    CACHE_TTL = 20.seconds
    CACHE_PREFIX = "inbox/history/v2"

    def self.call(...) = new(...).call

    def initialize(entry:, user: nil, limit: DEFAULT_LIMIT, before: nil)
      @entry = entry
      @user = user
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @before = before
    end

    # @spec OPERATOR-INBOX-022 OPERATOR-INBOX-025 OPERATOR-INBOX-028
    def call
      return Result.new(events: [], incomplete: false, next_cursor: nil, summary: empty_summary) unless subject_key

      returned = capture_return!
      projection = if cacheable? && !returned
        Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
          ActionHistoryPage.projection_for(entry:, subject_key:, limit:, before:)
        end
      else
        ActionHistoryPage.projection_for(entry:, subject_key:, limit:, before:)
      end
      return Result.new(events: [], incomplete: legacy_coverage?, next_cursor: nil,
        summary: projection&.summary || empty_summary) unless projection&.events

      page = projection.events.first(limit + 1)
      visible = page.first(limit)
      Result.new(events: visible, incomplete: legacy_coverage?, next_cursor: page[limit] ? visible.last.id : nil,
        summary: projection.summary)
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
    end

    def self.cache_key_for(account_id:, subject_key:)
      "#{CACHE_PREFIX}/#{account_id}/#{subject_key}"
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

    def empty_summary
      Summary.new(processing_attempts: 0, inbox_returns: 0, retry_limits: 0, token_budget_exceeded: 0)
    end

    # Cache only the default read-only page. Cursor pages are infrequent and
    # keeping arbitrary cursors out of the cache bounds its size.
    def cacheable?
      before.blank? && limit == DEFAULT_LIMIT
    end

    def cache_key
      self.class.cache_key_for(account_id: entry.project.account_id, subject_key:)
    end
  end
end
