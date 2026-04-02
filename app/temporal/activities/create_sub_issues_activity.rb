# frozen_string_literal: true

module Activities
  # Creates GitHub sub-issues from a decomposed plan and links them
  # to the parent issue using Paid's parent-child relationship system.
  #
  # NOTE: This activity is designed to be invoked from PlanningWorkflow
  # once the workflow layer is implemented. See #695 for the full scope.
  #
  # Input:
  #   project_id:      [Integer] The project to create issues in
  #   parent_issue_id: [Integer] The parent Issue record id
  #   sub_tasks:       [Array<Hash>] Each with :title, :body keys
  #
  # Returns:
  #   Hash with :parent_issue_id, :created_issues (array of hashes with
  #   :github_number, :github_issue_id, :issue_id, :title)
  class CreateSubIssuesActivity < BaseActivity
    activity_name "CreateSubIssues"

    def execute(input)
      project = Project.find(input[:project_id])
      parent_issue = project.issues.find(input[:parent_issue_id])
      sub_tasks = Array(input[:sub_tasks])

      client = project.github_token.client
      created_issues = []

      sub_tasks.each_with_index do |task, index|
        heartbeat("creating_sub_issue_#{index + 1}_of_#{sub_tasks.size}")

        title = task[:title].to_s.truncate(Llm::GenerateIssueTitle::MAX_TITLE_LENGTH)
        body = build_body(task[:body], parent_issue)
        labels = build_labels(project)

        gh_issue = client.create_issue(
          project.full_name,
          title: title,
          body: body,
          labels: labels
        )

        issue = sync_issue_record(project, gh_issue, parent_issue)

        created_issues << {
          github_number: gh_issue.number,
          github_issue_id: gh_issue.id,
          issue_id: issue&.id,
          title: title
        }

        logger.info(
          message: "orchestration.sub_issue_created",
          project_id: project.id,
          parent_issue_id: parent_issue.id,
          sub_issue_number: gh_issue.number
        )
      end

      {
        parent_issue_id: parent_issue.id,
        created_issues: created_issues
      }
    end

    private

    def build_body(task_body, parent_issue)
      parts = []
      parts << task_body.to_s.truncate(50_000) if task_body.present?
      parts << "---"
      parts << "Sub-issue of ##{parent_issue.github_number}"
      parts.join("\n\n")
    end

    def build_labels(project)
      labels = []
      labels << project.automation_label_name if project.automation_on_label_enabled?
      labels << project.generated_label_name if project.auto_add_labels_enabled?
      labels
    end

    def sync_issue_record(project, gh_issue, parent_issue)
      issue = project.issues.find_or_initialize_by(github_issue_id: gh_issue.id)
      issue.update!(
        github_number: gh_issue.number,
        title: gh_issue.title,
        body: gh_issue.body,
        github_creator_login: gh_issue.user&.login || "unknown",
        github_state: gh_issue.state,
        labels: (gh_issue.labels || []).map { |l| l.respond_to?(:name) ? l.name : l.to_s },
        is_pull_request: false,
        github_created_at: gh_issue.created_at,
        github_updated_at: gh_issue.updated_at,
        parent_issue: parent_issue
      )
      issue
    rescue => e
      logger.warn(
        message: "orchestration.sync_sub_issue_failed",
        project_id: project.id,
        issue_number: gh_issue.number,
        error: e.message
      )
      nil
    end
  end
end
