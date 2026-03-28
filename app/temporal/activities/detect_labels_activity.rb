# frozen_string_literal: true

module Activities
  # Checks an issue's labels against a project's label mappings to determine
  # what action should be taken (execute agent, start planning, or none).
  #
  # Updates the issue's paid_state when an action is triggered.
  class DetectLabelsActivity < BaseActivity
    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      project = Project.find(project_id)
      issue = project.issues.find(issue_id)

      action = determine_action(project, issue)

      if action != "none"
        new_state = (action == "execute_agent") ? "in_progress" : "planning"
        issue.update!(paid_state: new_state)
      end

      logger.info(
        message: "github_sync.detect_labels",
        project_id: project_id,
        issue_id: issue_id,
        action: action
      )

      result = { action: action, issue_id: issue_id, project_id: project_id }
      result[:source_pull_request_number] = issue.github_number if issue.is_pull_request? && action != "none"
      result
    rescue GithubClient::RateLimitError => e
      raise Temporalio::Error::ApplicationError.new(
        e.message,
        type: "RateLimit"
      )
    end

    private

    def determine_action(project, issue)
      return "none" unless issue.paid_state == "new"

      trigger = triggering_label(project, issue)
      return "none" unless trigger
      return "none" unless authorized_for_trigger?(project, issue, trigger[:label])

      # Check dependencies after labels to avoid unnecessary DB queries for unlabeled issues.
      # Pluck first (capped) to combine the existence check with data retrieval in one query.
      max_logged = 10
      blocking_relation = issue.blocking_issues
      blocking_numbers = blocking_relation.limit(max_logged + 1).pluck(:github_number)

      unless blocking_numbers.empty?
        blocking_issues_truncated = blocking_numbers.length > max_logged
        blocking_issues_to_log = blocking_numbers.first(max_logged)
        blocking_issues_count = blocking_issues_truncated ? blocking_relation.count : blocking_numbers.length

        logger.info(
          message: "github_sync.blocked_by_dependencies",
          project_id: project.id,
          issue_id: issue.id,
          blocking_issues: blocking_issues_to_log,
          blocking_issues_count: blocking_issues_count,
          blocking_issues_truncated: blocking_issues_truncated
        )
        return "none"
      end

      trigger[:action]
    end

    def triggering_label(project, issue)
      build_label = project.label_for_stage(:build)
      return { action: "execute_agent", label: build_label } if build_label && issue.has_label?(build_label)

      plan_label = project.label_for_stage(:plan)
      return { action: "start_planning", label: plan_label } if plan_label && issue.has_label?(plan_label)

      if project.automation_on_label_enabled? && issue.has_label?(project.automation_label_name)
        return { action: "execute_agent", label: project.automation_label_name }
      end

      nil
    end

    def authorized_for_trigger?(project, issue, label)
      return true if issue.trusted?
      return true if trusted_user_added_label?(project, issue, label)

      logger.warn(
        message: "github_sync.untrusted_issue_blocked",
        project_id: project.id,
        issue_id: issue.id,
        creator: issue.github_creator_login,
        label: label
      )
      false
    end

    def trusted_user_added_label?(project, issue, label)
      client = project.github_token.client
      events = client.issue_events(project.full_name, issue.github_number)

      # Walk label/unlabel events in chronological order to determine who
      # last caused the label to become present. This prevents a bypass where
      # a trusted user once added the label but later removed it and an
      # untrusted user re-added it.
      relevant = events.select do |event|
        (event.event == "labeled" || event.event == "unlabeled") &&
          event_label_name(event) == label
      end

      return false if relevant.empty?

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

      label_present && project.trusted_github_user?(last_labeled_actor)
    rescue GithubClient::RateLimitError
      raise
    rescue => e
      logger.warn(
        message: "github_sync.issue_events_fetch_failed",
        project_id: project.id,
        issue_id: issue.id,
        github_number: issue.github_number,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    def event_label_name(event)
      label = event.label
      return label.name if label.respond_to?(:name)

      label&.[]("name") || label&.[](:name)
    end
  end
end
