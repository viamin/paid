# frozen_string_literal: true

module Automation
  module LabelPolicy
    # Module-level label-history questions, for callers that are not mixin
    # hosts (the PR scanner). Both replay the pull request's label events
    # rather than reading the current label set, because a label's absence
    # does not say who removed it — or whether it was ever applied.
    class << self
      def trusted_user_added_label?(project, record, label)
        state = replay_label_events(project, record, label)
        return false unless state

        state[:present] && project.trusted_github_user?(state[:added_by])
      end

      # @spec PR-ESCALATION-009 @spec PR-ESCALATION-019
      def trusted_user_removed_label?(project, record, label)
        state = replay_label_events(project, record, label)
        return false unless state

        !state[:present] && project.trusted_github_user?(state[:removed_by])
      end

      # Replays the labeled/unlabeled history for one label and reports the
      # final state plus who put it there or took it away. Returns nil when the
      # history cannot be read, so callers treat "unknown" as "no evidence"
      # rather than inferring intent from a missing label.
      def replay_label_events(project, record, label)
        events = project.client.issue_events(project.full_name, record.github_number)
        relevant = Array(events).select do |event|
          (event.event == "labeled" || event.event == "unlabeled") &&
            event_label_name(event) == label
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
      rescue GithubClient::RateLimitError
        raise
      rescue => e
        Rails.logger.warn(
          message: "github_sync.issue_events_fetch_failed",
          project_id: project.id,
          issue_id: record.id,
          error: e.message
        )
        nil
      end

      def event_label_name(event)
        event.respond_to?(:label) && event.label ? event.label.name : nil
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

      if project.automation_on_label_enabled? &&
          !record.is_pull_request? &&
          record.has_label?(project.automation_label_name)
        return { action: "queue_create_pr_run", label: project.automation_label_name }
      end

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

    def trusted_user_added_label?(project, record, label)
      @trusted_user_added_label_cache ||= {}
      cache_key = [ project.id, record.github_number, label ]
      return @trusted_user_added_label_cache[cache_key] if @trusted_user_added_label_cache.key?(cache_key)

      events = project.client.issue_events(project.full_name, record.github_number)
      relevant = events.select do |event|
        (event.event == "labeled" || event.event == "unlabeled") &&
          event_label_name(event) == label
      end
      return @trusted_user_added_label_cache[cache_key] = false if relevant.empty?

      sorted = relevant.sort_by do |event|
        event.respond_to?(:created_at) && event.created_at ? event.created_at : Time.at(0)
      end

      label_present = false
      last_labeled_actor = nil

      sorted.each do |event|
        case event.event
        when "labeled"
          label_present = true
          last_labeled_actor = event.actor&.login
        when "unlabeled"
          label_present = false
          last_labeled_actor = nil
        end
      end

      @trusted_user_added_label_cache[cache_key] = label_present && project.trusted_github_user?(last_labeled_actor)
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
      @trusted_user_added_label_cache[cache_key] = false
    end

    def event_label_name(event)
      label = event.label
      return label.name if label.respond_to?(:name)

      label&.[]("name") || label&.[](:name)
    end

    def label_decision_for(project, record)
      return Result.noop unless actionable_state?(record)

      trigger = triggering_label(project, record)
      return Result.noop unless trigger
      return Result.noop unless authorized_for_trigger?(project, record, trigger[:label])
      return Result.noop if blocked_by_dependencies?(project, record)

      decision = case trigger[:action]
      when "queue_create_pr_run"
        Decision.queue_create_pr_run(
          issue_id: record.id,
          source_pull_request_number: record.is_pull_request? ? record.github_number : nil
        )
      when "start_planning"
        Decision.start_planning(issue_id: record.id)
      else
        Decision.noop
      end

      Result.new(decisions: [ decision ])
    end
  end
end
