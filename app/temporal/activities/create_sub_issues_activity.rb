# frozen_string_literal: true

module Activities
  # Creates GitHub sub-issues from a decomposed plan and links them
  # to the parent issue using Paid's parent-child relationship system.
  #
  # NOTE: This activity is designed to be invoked from PlanningWorkflow
  # once the workflow layer is implemented. See #695 for the full scope.
  #
  # Idempotency: this activity creates GitHub issues as a side effect and is
  # safe to retry. Each task is deduped by parent issue + truncated title, so
  # a Temporal retry (worker crash after creating some sub-issues) reuses the
  # already-created issues instead of duplicating them (#2770).
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
    STANDARD_MODE = "standard"
    ORCHESTRATION_MODE = "orchestration"

    activity_name "CreateSubIssues"

    def execute(input)
      project = Project.find(input[:project_id])
      parent_issue = project.issues.find(input[:parent_issue_id])
      sub_tasks = validate_sub_tasks!(input[:sub_tasks])
      creation_mode = validate_creation_mode!(input[:creation_mode])

      client = project.client
      created_issues = []
      creation_order = topological_sort!(sub_tasks)
      index_to_github_number = {}

      create_or_reuse_sub_issues(
        sub_tasks, created_issues, client, project, parent_issue, creation_mode,
        creation_order, index_to_github_number
      )

      {
        parent_issue_id: parent_issue.id,
        created_issues: created_issues
      }
    end

    private

    def create_or_reuse_sub_issues(
      sub_tasks, created_issues, client, project, parent_issue, creation_mode,
      creation_order, index_to_github_number
    )
      resolved = ProjectConventions::IssueDependencies.convention_value(project)

      creation_order.each_with_index do |task_index, step|
        task = sub_tasks[task_index]
        heartbeat("creating_sub_issue_#{step + 1}_of_#{creation_order.size}")

        title = task[:title].to_s.truncate(Llm::GenerateIssueTitle::MAX_TITLE_LENGTH)

        existing = existing_sub_issue(project, parent_issue, title)
        if existing
          index_to_github_number[task_index] = existing.github_number
          created_issues << {
            index: task_index,
            github_number: existing.github_number,
            github_issue_id: existing.github_issue_id,
            issue_id: existing.id,
            title: title
          }
          logger.info(
            message: "orchestration.sub_issue_reused",
            project_id: project.id,
            parent_issue_id: parent_issue.id,
            sub_issue_number: existing.github_number
          )
          next
        end

        body = build_body(task, project, parent_issue, creation_mode, index_to_github_number, resolved: resolved)
        labels = build_labels(project, creation_mode)

        gh_issue = client.create_issue(
          project.full_name,
          title: title,
          body: body,
          labels: labels
        )

        index_to_github_number[task_index] = gh_issue.number
        issue = sync_issue_record(project, gh_issue, parent_issue, creation_mode)

        created_issues << {
          index: task_index,
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
    rescue Temporalio::Error::CanceledError
      raise
    end

    # Idempotency: a Temporal retry (or a re-trigger) must not duplicate a
    # sub-issue that a previous attempt already created. We match on the
    # parent issue + truncated title, which is the stable, persisted identity
    # of a decomposed task. GitHub-issue-created-but-not-yet-synced races are
    # out of scope (the local record is the source of truth for "created").
    def existing_sub_issue(project, parent_issue, title)
      project.issues.where(parent_issue_id: parent_issue.id, title: title).first
    end

    def validate_sub_tasks!(sub_tasks)
      raise Temporalio::Error::ApplicationError.new(
        "sub_tasks must be an Array", type: "InvalidInput", non_retryable: true
      ) unless sub_tasks.is_a?(Array)

      sub_tasks.each_with_index do |task, index|
        raise Temporalio::Error::ApplicationError.new(
          "sub_tasks[#{index}] must be a Hash", type: "InvalidInput", non_retryable: true
        ) unless task.is_a?(Hash)

        raise Temporalio::Error::ApplicationError.new(
          "sub_tasks[#{index}] must have a non-blank title", type: "InvalidInput", non_retryable: true
        ) if task[:title].to_s.blank?
      end

      sub_tasks
    end

    def validate_creation_mode!(creation_mode)
      mode = creation_mode.presence || STANDARD_MODE
      return mode if [ STANDARD_MODE, ORCHESTRATION_MODE ].include?(mode)

      raise Temporalio::Error::ApplicationError.new(
        "creation_mode must be #{STANDARD_MODE.inspect} or #{ORCHESTRATION_MODE.inspect}",
        type: "InvalidInput",
        non_retryable: true
      )
    end

    def build_body(task, project, parent_issue, creation_mode, index_to_github_number, resolved: nil)
      parts = []
      task_body = task[:body].presence || task[:description]
      parts << task_body.to_s.truncate(50_000) if task_body.present?
      parts << "---"
      parts << "Sub-issue of ##{parent_issue.github_number}"

      if creation_mode == ORCHESTRATION_MODE
        resolved ||= ProjectConventions::IssueDependencies.convention_value(project)
        dependency_lines = Array(task[:dependencies]).filter_map do |dependency_index|
          dependency_number = index_to_github_number[dependency_index]
          ProjectConventions::IssueDependencies.depends_on_line(
            project:,
            github_number: dependency_number,
            resolved:
          ) if dependency_number
        end

        if dependency_lines.any?
          parts << ProjectConventions::IssueDependencies.heading(project: project, resolved:)
          parts << dependency_lines.map { |line| "- #{line}" }.join("\n")
        end
      end

      parts.join("\n\n")
    end

    def build_labels(project, creation_mode)
      labels = []
      if creation_mode != ORCHESTRATION_MODE && project.automation_on_label_enabled?
        labels << project.automation_label_name
      end
      labels << project.generated_label_name if project.auto_add_labels_enabled?
      labels
    end

    def sync_issue_record(project, gh_issue, parent_issue, creation_mode)
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
        paid_state: paid_state_for(creation_mode),
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
      raise Temporalio::Error::ApplicationError.new(
        "Failed to sync orchestration sub-issue ##{gh_issue.number} locally: #{e.message}",
        type: "SubIssueSyncFailed",
        non_retryable: true
      ) if creation_mode == ORCHESTRATION_MODE

      nil
    end

    def paid_state_for(creation_mode)
      creation_mode == ORCHESTRATION_MODE ? "planning" : "new"
    end

    def topological_sort!(tasks)
      task_count = tasks.size
      in_degree = Array.new(task_count, 0)
      adjacency = Array.new(task_count) { [] }

      tasks.each_with_index do |task, task_index|
        Array(task[:dependencies]).each do |dependency_index|
          next unless dependency_index >= 0 && dependency_index < task_count

          adjacency[dependency_index] << task_index
          in_degree[task_index] += 1
        end
      end

      queue = (0...task_count).select { |task_index| in_degree[task_index].zero? }
      sorted = []

      until queue.empty?
        node = queue.shift
        sorted << node
        adjacency[node].each do |neighbor|
          in_degree[neighbor] -= 1
          queue << neighbor if in_degree[neighbor].zero?
        end
      end

      return sorted if sorted.size == task_count

      raise Temporalio::Error::ApplicationError.new(
        "Dependency cycle detected in sub_tasks — cannot determine creation order",
        type: "InvalidInput",
        non_retryable: true
      )
    end
  end
end
