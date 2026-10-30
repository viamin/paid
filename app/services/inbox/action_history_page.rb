# frozen_string_literal: true

module Inbox
  # Executes one bounded query per history stream and merges only those
  # candidates in memory. The cursor uses the projection's global time/id sort.
  # @spec OPERATOR-INBOX-022
  class ActionHistoryPage
    Cursor = Data.define(:id, :occurred_at)
    RUN_OUTCOMES = {
      "completed" => [ "Agent run completed", "completed" ],
      "no_output" => [ "Agent run completed with no output", "no_output" ],
      "failed" => [ "Agent run failed", "failed" ],
      "cancelled" => [ "Agent run cancelled", "cancelled" ],
      "timeout" => [ "Agent run timed out", "failed" ],
      "token_budget_exceeded" => [ "Agent run exceeded its token budget", "failed" ],
      "retried" => [ "Agent run retried", "retried" ],
      "auth_expired" => [ "Agent run authentication expired", "failed" ],
      "rate_limited" => [ "Agent run was rate limited", "failed" ]
    }.freeze

    def self.call(...) = new(...).call

    def initialize(entry:, subject_key:, limit:, before:)
      @entry, @subject_key, @limit, @before = entry, subject_key, limit, before
    end

    def call
      return if before && cursor.nil?

      (persisted_events + run_start_events + run_finish_events + feature_approval_events + feature_release_events)
        .sort_by { |event| [ -event.occurred_at.to_f, event.id ] }
    end

    private

    attr_reader :before, :entry, :limit, :subject_key

    def persisted_events
      bounded(history_scope, "occurred_at", "'history:' || id::text").map do |event|
        ActionHistory::Event.new(id: "history:#{event.id}", action: event.metadata.fetch("action", event.event_key),
          actor: event.actor_label, source: event.source, result: event.result, occurred_at: event.occurred_at,
          revision: event.revision, evidence_url: safe_evidence_url(event.evidence_url))
      end
    end

    def run_start_events
      return [] unless entry.issue

      bounded(runs, "COALESCE(started_at, created_at)", "'run-start:' || id::text").map do |run|
        ActionHistory::Event.new(id: "run-start:#{run.id}", action: "Agent run started", actor: "Paid", source: "paid",
          result: "attempted", occurred_at: run.started_at || run.created_at, revision: run.base_commit_sha,
          evidence_url: safe_evidence_url(run.pull_request_url))
      end
    end

    def run_finish_events
      return [] unless entry.issue

      bounded(runs.where(status: RUN_OUTCOMES.keys).where.not(completed_at: nil),
        "completed_at", "'run-finish:' || id::text").map do |run|
        action, result = RUN_OUTCOMES.fetch(run.status)
        ActionHistory::Event.new(id: "run-finish:#{run.id}", action:, actor: "Paid", source: "paid",
          result:, occurred_at: run.completed_at, revision: run.result_commit_sha,
          evidence_url: safe_evidence_url(run.pull_request_url) || safe_evidence_url(run.review_url))
      end
    end

    def feature_approval_events
      return [] unless feature

      bounded(feature.feature_intent_approval_revisions.includes(:approved_by), "approved_at",
        "'feature-approval:' || id::text").map do |approval|
        ActionHistory::Event.new(id: "feature-approval:#{approval.id}", action: "Feature approved",
          actor: approval.approved_by.email, source: approval.source, result: "completed",
          occurred_at: approval.approved_at, revision: approval_revision(approval), evidence_url: nil)
      end
    end

    def approval_revision(approval)
      approval.pr_heads.sort.map { |number, sha| "##{number}@#{sha}" }.join(", ")
    end

    def feature_release_events
      return [] unless feature

      bounded(feature_release_scope.includes(:actor), "created_at", "'feature-release:' || id::text").map do |release|
        metadata = release.metadata.deep_stringify_keys
        ActionHistory::Event.new(id: "feature-release:#{release.id}", action: "Feature released",
          actor: release.actor_label, source: metadata.fetch("source", "paid"), result: "completed",
          occurred_at: release.created_at, revision: metadata["merged_revision"], evidence_url: nil)
      end
    end

    def bounded(relation, time_sql, id_sql)
      time_expression = Arel.sql(time_sql)
      id_expression = Arel.sql(id_sql)
      relation = relation.where(cursor_predicate(time_expression, id_expression)) if cursor
      relation.order(time_expression.desc, id_expression.asc).limit(limit + 1)
    end

    def cursor_predicate(time_expression, id_expression)
      time_expression.lt(cursor.occurred_at).or(
        time_expression.eq(cursor.occurred_at).and(id_expression.gt(cursor.id))
      )
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
      return feature_cursor(type, id) if feature
      return unless entry.issue && %w[run-start run-finish].include?(type)

      run = runs.find_by(id:)
      occurred_at = type == "run-start" ? run&.started_at || run&.created_at : run&.completed_at
      Cursor.new(id: before, occurred_at:) if occurred_at
    end

    def feature_cursor(type, id)
      occurred_at = case type
      when "feature-approval" then feature.feature_intent_approval_revisions.find_by(id:)&.approved_at
      when "feature-release" then feature_release_scope.find_by(id:)&.created_at
      end
      Cursor.new(id: before, occurred_at:) if occurred_at
    end

    def history_scope
      InboxHistoryEvent.for_subject(account: entry.project.account, subject_key:)
    end

    def safe_evidence_url(url)
      url if ApplicationController.helpers.safe_github_url?(url)
    end

    def runs
      entry.project.agent_runs.where(issue: entry.issue)
        .or(entry.project.agent_runs.where(source_pull_request_number: entry.issue.github_number))
    end

    def feature
      entry.record if entry.record.is_a?(FeatureIntent)
    end

    def feature_release_scope
      entry.project.account.account_activity_events.where(
        action: "feature_intent.released", subject: feature
      )
    end
  end
end
