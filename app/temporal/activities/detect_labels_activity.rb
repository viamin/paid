# frozen_string_literal: true

module Activities
  # Checks an issue's labels against a project's label mappings to determine
  # what action should be taken (execute agent, start planning, or none).
  #
  # Updates the issue's paid_state when an action is triggered.
  class DetectLabelsActivity < BaseActivity
    def execute(project_id:, issue_id:)
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

      { action: action, issue_id: issue_id, project_id: project_id }
    end

    private

    def determine_action(project, issue)
      return "none" unless issue.paid_state == "new"

      build_label = project.label_for_stage(:build)
      plan_label = project.label_for_stage(:plan)

      if build_label && issue.has_label?(build_label)
        "execute_agent"
      elsif plan_label && issue.has_label?(plan_label)
        "start_planning"
      else
        "none"
      end
    end
  end
end
