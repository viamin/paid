# frozen_string_literal: true

module Automation
  module LabelPolicy
    # Module-level label-history questions, for callers that are not mixin
    # hosts (the PR scanner). Both replay the pull request's label events
    # rather than reading the current label set, because a label's absence
    # does not say who removed it — or whether it was ever applied.
    class << self
      # Bounded memo of the raw label-event fetches behind the module-level
      # trust checks. One evaluation consults the same record's events
      # several times (auto-pick + enhancement + catchall labels), and the
      # fetch cost is per record — not per label — so the replay is cheap
      # once the events are in hand. Freshness is scoped to a single unit
      # of work: BaseActivity clears this memo at the start of every
      # activity task and ApplicationJob at the start of every perform, so a
      # repeated execute/perform on a long-lived temporal worker or GoodJob
      # thread never observes a prior pass's events. The MemoryStore adds a
      # size-bounded LRU plus TTL expiry as a backstop for any caller that
      # is not already inside one of those unit-of-work boundaries.
      LABEL_EVENT_CACHE = ActiveSupport::Cache::MemoryStore.new(size: 1.megabyte)
      LABEL_EVENT_CACHE_TTL = 1.minute
      private_constant :LABEL_EVENT_CACHE, :LABEL_EVENT_CACHE_TTL

      # Operational hook: drops every cached label-event fetch so a new
      # unit of work re-reads fresh history from GitHub. Called at each
      # activity-task and job-perform boundary (see BaseActivity and
      # ApplicationJob) and between test examples.
      def clear_label_event_cache!
        LABEL_EVENT_CACHE.clear
      end

      def trusted_user_added_label?(project, record, label)
        state = replay_label_events(project, record, label)
        return false unless state

        state[:present] && project.trusted_github_user?(state[:added_by])
      end

      # +after+ bounds the replay to events at or after the given time — used
      # by escalation-dismissal detection to ignore label events from a prior
      # escalation cycle. Without it, an owner's `unlabeled` event from a
      # previous cycle satisfies this check on a subsequent re-escalation whose
      # own label write failed, granting a full counter reset (and, for
      # token-cap escalations, the permanent waiver) that the owner never asked
      # for. Callers with no cycle marker pass +nil+ and get the unbounded
      # replay.
      # @spec PR-ESCALATION-009 @spec PR-ESCALATION-019
      def trusted_user_removed_label?(project, record, label, after: nil)
        state = replay_label_events(project, record, label, after: after)
        return false unless state

        !state[:present] && project.trusted_github_user?(state[:removed_by])
      end

      # Replays the labeled/unlabeled history for one label and reports the
      # final state plus who put it there or took it away. Returns nil when the
      # history cannot be read, so callers treat "unknown" as "no evidence"
      # rather than inferring intent from a missing label. +after+ restricts
      # the replay to events at or after that timestamp.
      def replay_label_events(project, record, label, after: nil)
        events = label_events_for(project, record)
        return nil unless events

        relevant = events.select do |event|
          (event.event == "labeled" || event.event == "unlabeled") &&
            event_label_name(event) == label &&
            event_after?(event, after)
        end
        return { present: false, added_by: nil, removed_by: nil } if relevant.empty?

        relevant
          .sort_by { |event| event.respond_to?(:created_at) && event.created_at ? event.created_at : Time.at(0) }
          .each_with_object({ present: false, added_by: nil, removed_by: nil }) do |event, state|
            if event.event == "labeled"
              state[:present] = true
              state[:added_by] = event.actor&.login
              state[:removed_by] = nil
            else
              state[:present] = false
              state[:removed_by] = event.actor&.login
              state[:added_by] = nil
            end
          end
      end

      # Raw label-event history for one record, served from the bounded TTL
      # cache above so repeated trust checks for the same record share a
      # single GitHub API call. Returns nil when the history cannot be read.
      def label_events_for(project, record)
        LABEL_EVENT_CACHE.fetch([ project.id, record.github_number ], expires_in: LABEL_EVENT_CACHE_TTL) do
          Array(project.client.issue_events(project.full_name, record.github_number))
        end
      rescue GithubClient::RateLimitError
        raise
      rescue => e
        Rails.logger.warn(
          message: "github_sync.issue_events_fetch_failed",
          project_id: project.id,
          issue_id: record.id,
          github_number: record.github_number,
          error_class: e.class.name,
          error: e.message
        )
        nil
      end

      def event_label_name(event)
        label = event.respond_to?(:label) && event.label
        return nil unless label
        return label.name if label.respond_to?(:name)

        label["name"] || label[:name] if label.respond_to?(:[])
      end

      # Events without a timestamp are treated as "before any bound" so a
      # missing +created_at+ cannot be mistaken for a fresh cycle event.
      def event_after?(event, after)
        return true unless after
        return false unless event.respond_to?(:created_at) && event.created_at

        event.created_at >= after
      end
    end

    private

    def actionable_state?(record)
      record.paid_state.in?(%w[new needs_input recommend_close analyzed])
    end

    def triggering_label(project, record)
      build_label = project.label_for_stage(:build)
      return { action: "queue_create_pr_run", label: build_label } if build_label && record.has_label?(build_label)

      plan_label = project.label_for_stage(:plan)
      return { action: "start_planning", label: plan_label } if plan_label && record.has_label?(plan_label)

      return activation_trigger(project, record) unless record.is_pull_request?

      nil
    end

    def authorized_for_trigger?(project, record, label)
      return true if record.trusted?
      return true if trusted_user_added_label?(project, record, label)

      Rails.logger.warn(
        message: "github_sync.untrusted_issue_blocked",
        project_id: project.id,
        issue_id: record.id,
        creator: record.github_creator_login,
        label: label
      )
      false
    end

    # @spec AUTOMATION-ACTIVATION-003 @spec AUTOMATION-ACTIVATION-006
    # The activation label path still honors the automation_on_label_enabled
    # master switch: a project that turned label-triggered automation off
    # (e.g. the observe_only configuration profile) must not be re-armed by
    # an activation label. #3804 excludes that setting from getting its own
    # activation label; it does not exempt the setting from the gate.
    def activation_trigger(project, record)
      return nil unless project.automation_on_label_enabled?

      activation_label = FeatureActivation.issue_auto_pick_trigger(project:, issue: record)
      return nil unless activation_label

      action = if FeatureActivation.issue_auto_enhance_enabled?(project:, issue: record)
        "queue_analyze_issue_run"
      else
        "queue_create_pr_run"
      end

      { action: action, label: activation_label, trust_label_only: true }
    end

    def blocked_by_dependencies?(project, record)
      max_logged = 10
      blocking_relation = record.blocking_issues
      blocking_numbers = blocking_relation.limit(max_logged + 1).pluck(:github_number)
      return false if blocking_numbers.empty?

      blocking_issues_truncated = blocking_numbers.length > max_logged
      blocking_issues_to_log = blocking_numbers.first(max_logged)
      blocking_issues_count = blocking_issues_truncated ? blocking_relation.count : blocking_numbers.length

      Rails.logger.info(
        message: "github_sync.blocked_by_dependencies",
        project_id: project.id,
        issue_id: record.id,
        blocking_issues: blocking_issues_to_log,
        blocking_issues_count: blocking_issues_count,
        blocking_issues_truncated: blocking_issues_truncated
      )

      true
    end

    # Delegates to the module-level trust check, which replays the label
    # events through the bounded TTL cache — one GitHub API call per record
    # regardless of how many labels are checked against it.
    def trusted_user_added_label?(project, record, label)
      Automation::LabelPolicy.trusted_user_added_label?(project, record, label)
    end

    def label_decision_for(project, record)
      return Result.noop unless actionable_state?(record)

      trigger = triggering_label(project, record)
      return Result.noop unless trigger
      if trigger[:trust_label_only]
        return Result.noop unless trusted_user_added_label?(project, record, trigger[:label])
      else
        return Result.noop unless authorized_for_trigger?(project, record, trigger[:label])
      end
      return Result.noop if blocked_by_dependencies?(project, record)

      decision = case trigger[:action]
      when "queue_create_pr_run"
        Decision.queue_create_pr_run(
          issue_id: record.id,
          source_pull_request_number: record.is_pull_request? ? record.github_number : nil
        )
      when "queue_analyze_issue_run"
        Decision.queue_analyze_issue_run(issue_id: record.id)
      when "start_planning"
        Decision.start_planning(issue_id: record.id)
      else
        Decision.noop
      end

      Result.new(decisions: [ decision ])
    end
  end
end
