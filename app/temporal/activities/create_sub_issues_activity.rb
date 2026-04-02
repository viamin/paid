# frozen_string_literal: true

module Activities
  # Creates GitHub sub-issues from a decomposed feature plan.
  # Each task becomes a sub-issue linked to the parent feature issue.
  class CreateSubIssuesActivity < BaseActivity
    activity_name "CreateSubIssues"

    def execute(input)
      project_id = input[:project_id]
      parent_issue_id = input[:parent_issue_id]
      tasks = input[:tasks] || []

      project = Project.find(project_id)
      parent_issue = project.issues.find(parent_issue_id)
      client = project.github_token.client

      created_issues = []
      sub_issue_ids = tasks.map do |task|
        issue = create_sub_issue(client, project, parent_issue, task, created_issues)
        created_issues << issue
        issue&.id
      end.compact

      logger.info(
        message: "planning.sub_issues_created",
        project_id: project_id,
        parent_issue_id: parent_issue_id,
        sub_issue_count: sub_issue_ids.size
      )

      { sub_issue_ids: sub_issue_ids }
    end

    private

    def create_sub_issue(client, project, parent_issue, task, created_issues)
      body = build_issue_body(task, parent_issue)
      labels = sub_issue_labels(project)

      gh_issue = client.create_issue(
        project.full_name,
        title: task[:title],
        body: body,
        labels: labels
      )

      issue = sync_issue_record(project, parent_issue, gh_issue)
      create_dependencies(issue, task[:dependencies], created_issues)

      heartbeat("created sub-issue ##{gh_issue.number}")

      issue
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "planning.create_sub_issue_failed",
        project_id: project.id,
        parent_issue_id: parent_issue.id,
        task_title: task[:title],
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    def build_issue_body(task, parent_issue)
      parts = []
      parts << task[:description]
      parts << ""
      parts << "---"
      parts << "Parent issue: ##{parent_issue.github_number}"
      parts << "Parallel group: #{task[:parallel_group]}" if task[:parallel_group]

      if task[:dependencies].present?
        parts << "Dependencies: #{task[:dependencies].map { |d| "task #{d}" }.join(", ")}"
      end

      parts.join("\n")
    end

    def sub_issue_labels(project)
      build_label = project.label_for_stage(:build)
      labels = []
      labels << build_label if build_label
      labels
    end

    def sync_issue_record(project, parent_issue, gh_issue)
      issue = project.issues.find_or_initialize_by(github_issue_id: gh_issue.id)
      issue.update!(
        github_number: gh_issue.number,
        title: gh_issue.title,
        body: gh_issue.body,
        github_creator_login: gh_issue.user&.login || "unknown",
        github_state: gh_issue.state,
        labels: (gh_issue.labels || []).map { |l| l.respond_to?(:name) ? l.name : l.to_s },
        is_pull_request: false,
        paid_state: "new",
        parent_issue: parent_issue,
        github_created_at: gh_issue.created_at,
        github_updated_at: gh_issue.updated_at
      )
      issue
    end

    def create_dependencies(issue, dependency_indices, created_issues)
      return if dependency_indices.blank?

      # Dependencies reference task indices. Use the in-memory array of issues
      # created in this run to resolve indices reliably.
      dependency_indices.each do |dep_index|
        dep_issue = created_issues[dep_index]
        next unless dep_issue && dep_issue.id != issue.id

        IssueDependency.find_or_create_by!(
          issue: issue,
          depends_on_issue: dep_issue
        )
      end
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "planning.create_dependency_failed",
        issue_id: issue.id,
        dependency_indices: dependency_indices,
        error_class: e.class.name,
        error: e.message
      )
    end
  end
end
