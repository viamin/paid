# frozen_string_literal: true

module Inbox
  # Executes one bounded query per history stream and merges only those
  # candidates in memory. The cursor uses the projection's global time/id sort.
  # @spec OPERATOR-INBOX-022
  class ActionHistoryPage
    Cursor = Data.define(:id, :occurred_at)

    def self.call(...) = new(...).call

    def initialize(entry:, subject_key:, limit:, before:)
      @entry, @subject_key, @limit, @before = entry, subject_key, limit, before
    end

    def call
      return if before && cursor.nil?

      (persisted_events + run_start_events + run_finish_events)
        .sort_by { |event| [ -event.occurred_at.to_f, event.id ] }
    end

    private

    attr_reader :before, :entry, :limit, :subject_key

    def persisted_events
      bounded(history_scope, "occurred_at", "'history:' || id::text").map do |event|
        ActionHistory::Event.new(id: "history:#{event.id}", action: event.metadata.fetch("action", event.event_key),
          actor: event.actor_label, source: event.source, result: event.result, occurred_at: event.occurred_at,
          revision: event.revision, evidence_url: event.evidence_url)
      end
    end

    def run_start_events
      return [] unless entry.issue

      bounded(runs, "COALESCE(started_at, created_at)", "'run-start:' || id::text").map do |run|
        ActionHistory::Event.new(id: "run-start:#{run.id}", action: "Agent run started", actor: "Paid", source: "paid",
          result: "attempted", occurred_at: run.started_at || run.created_at, revision: run.base_commit_sha,
          evidence_url: run.pull_request_url)
      end
    end

    def run_finish_events
      return [] unless entry.issue

      bounded(runs.where.not(completed_at: nil), "completed_at", "'run-finish:' || id::text").map do |run|
        result = run.status == "completed" ? "completed" : "failed"
        ActionHistory::Event.new(id: "run-finish:#{run.id}", action: "Agent run #{result}", actor: "Paid", source: "paid",
          result:, occurred_at: run.completed_at, revision: run.result_commit_sha,
          evidence_url: run.pull_request_url || run.review_url)
      end
    end

    def bounded(relation, time_sql, id_sql)
      relation = relation.where("#{time_sql} < :time OR (#{time_sql} = :time AND #{id_sql} > :id)",
        time: cursor.occurred_at, id: cursor.id) if cursor
      relation.order(Arel.sql("#{time_sql} DESC, #{id_sql} ASC")).limit(limit + 1)
    end

    def cursor
      return @cursor if defined?(@cursor)

      type, id = before.to_s.split(":", 2)
      @cursor = type == "history" ? history_cursor(id) : run_cursor(type, id)
    end

    def history_cursor(id)
      event = history_scope.find_by(id:)
      Cursor.new(id: before, occurred_at: event.occurred_at) if event
    end

    def run_cursor(type, id)
      return unless %w[run-start run-finish].include?(type)

      run = runs.find_by(id:)
      occurred_at = type == "run-start" ? run&.started_at || run&.created_at : run&.completed_at
      Cursor.new(id: before, occurred_at:) if occurred_at
    end

    def history_scope
      InboxHistoryEvent.for_subject(account: entry.project.account, subject_key:)
    end

    def runs
      entry.project.agent_runs.where(issue: entry.issue)
        .or(entry.project.agent_runs.where(source_pull_request_number: entry.issue.github_number))
    end
  end
end
