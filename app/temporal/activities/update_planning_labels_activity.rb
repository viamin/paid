# frozen_string_literal: true

module Activities
  # Updates labels on the parent issue after planning completes.
  # Removes the plan label and adds the planned/build label depending
  # on the decomposition result.
  class UpdatePlanningLabelsActivity < BaseActivity
    activity_name "UpdatePlanningLabels"

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      task_count = input[:task_count] || 0

      project = Project.find(project_id)
      issue = project.issues.find(issue_id)
      client = project.github_token.client

      update_labels(client, project, issue, task_count)
      update_paid_state(issue, task_count)

      logger.info(
        message: "planning.labels_updated",
        project_id: project_id,
        issue_id: issue_id,
        task_count: task_count
      )

      { success: true }
    end

    private

    def update_labels(client, project, issue, task_count)
      plan_label = project.label_for_stage(:plan)
      remove_label(client, project, issue, plan_label) if plan_label

      if task_count <= 1
        # Single-task feature: add build label directly to the parent issue
        build_label = project.label_for_stage(:build)
        add_label(client, project, issue, build_label) if build_label
      end
    end

    def update_paid_state(issue, task_count)
      if task_count <= 1
        issue.update!(paid_state: "in_progress")
      else
        issue.update!(paid_state: "planning")
      end
    end

    def add_label(client, project, issue, label)
      client.add_labels_to_issue(project.full_name, issue.github_number, [ label ])
    rescue => e
      logger.warn(
        message: "planning.add_label_failed",
        project_id: project.id,
        issue_id: issue.id,
        label: label,
        error: e.message
      )
    end

    def remove_label(client, project, issue, label)
      client.remove_label_from_issue(project.full_name, issue.github_number, label)
    rescue => e
      logger.warn(
        message: "planning.remove_label_failed",
        project_id: project.id,
        issue_id: issue.id,
        label: label,
        error: e.message
      )
    end
  end
end
