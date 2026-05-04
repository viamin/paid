# frozen_string_literal: true

module Activities
  # Creates multiple GitHub issues from a decomposition plan, wiring up
  # dependency declarations between them using `Depends on #N` syntax.
  #
  # Issues are created in topological (dependency) order so that dependency
  # issue numbers are known when creating dependent issues. If the plan
  # references a parent tracking issue, its body is updated with a task
  # list linking all created sub-issues.
  #
  # IMPORTANT: This activity creates GitHub issues as a side effect and is
  # NOT idempotent. If a failure occurs after some issues have been created,
  # the error is raised as non-retryable to prevent duplicate issues.
  # Callers should use a no-retry policy (max_attempts: 1).
  #
  # Input:
  #   agent_run_id:         [Integer] The agent run that produced the plan
  #   tasks:                [Array<Hash>] Each with :index, :title, :body, :dependencies
  #   parent_issue_number:  [Integer, nil] GitHub number of the parent tracking issue
  #
  # Returns:
  #   Hash with :agent_run_id, :created_issues, :parent_issue_updated
  class CreateMultipleIssuesActivity < BaseActivity
    activity_name "CreateMultipleIssues"

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      tasks = validate_tasks!(input[:tasks])
      parent_issue_number = input[:parent_issue_number]

      project = agent_run.project
      client = project.github_token.client

      creation_order = topological_sort(tasks)
      index_to_github_number = {}
      created_issues = []

      create_issues_with_partial_failure_guard(
        tasks, creation_order, index_to_github_number, created_issues,
        client, project, agent_run
      )

      complete_agent_run!(agent_run, created_issues)

      parent_updated = false
      if parent_issue_number && created_issues.any?
        parent_updated = update_parent_issue(
          client, project, parent_issue_number, created_issues
        )
      end

      {
        agent_run_id: agent_run.id,
        created_issues: created_issues,
        parent_issue_updated: parent_updated
      }
    end

    private

    def create_issues_with_partial_failure_guard(
      tasks, creation_order, index_to_github_number, created_issues,
      client, project, agent_run
    )
      creation_order.each_with_index do |task_index, step|
        task = tasks[task_index]
        heartbeat("creating_issue_#{step + 1}_of_#{creation_order.size}")

        title = task[:title].to_s.truncate(Llm::GenerateIssueTitle::MAX_TITLE_LENGTH)
        body = build_body(task, index_to_github_number)
        labels = build_labels(project)

        gh_issue = client.create_issue(
          project.full_name,
          title: title,
          body: body,
          labels: labels
        )

        index_to_github_number[task_index] = gh_issue.number
        issue_record = sync_issue_record(project, gh_issue)

        created_issues << {
          index: task_index,
          github_number: gh_issue.number,
          github_issue_id: gh_issue.id,
          issue_id: issue_record&.id,
          title: title,
          issue_url: gh_issue.html_url
        }

        logger.info(
          message: "agent_execution.multi_issue_created",
          agent_run_id: agent_run.id,
          project_id: project.id,
          issue_number: gh_issue.number,
          step: "#{step + 1}/#{creation_order.size}"
        )
      end
    rescue Temporalio::Error::CanceledError
      raise
    rescue StandardError => e
      raise e if created_issues.empty?

      raise Temporalio::Error::ApplicationError.new(
        "Partial failure after creating #{created_issues.size}/#{creation_order.size} issues: #{e.message}",
        type: "MultiIssueCreationPartialFailure",
        non_retryable: true
      )
    end

    def validate_tasks!(tasks)
      raise Temporalio::Error::ApplicationError.new(
        "tasks must be a non-empty Array", type: "InvalidInput", non_retryable: true
      ) unless tasks.is_a?(Array) && tasks.any?

      tasks.each_with_index do |task, i|
        raise Temporalio::Error::ApplicationError.new(
          "tasks[#{i}] must be a Hash", type: "InvalidInput", non_retryable: true
        ) unless task.is_a?(Hash)

        raise Temporalio::Error::ApplicationError.new(
          "tasks[#{i}] must have a non-blank title", type: "InvalidInput", non_retryable: true
        ) if task[:title].to_s.blank?
      end

      tasks
    end

    def build_body(task, index_to_github_number)
      parts = []
      parts << task[:body].to_s.truncate(50_000) if task[:body].present?

      dep_indices = Array(task[:dependencies])
      if dep_indices.any?
        dep_lines = dep_indices.filter_map do |dep_index|
          gh_number = index_to_github_number[dep_index]
          "Depends on ##{gh_number}" if gh_number
        end

        if dep_lines.any?
          parts << "## Dependencies"
          parts << dep_lines.join("\n")
        end
      end

      parts.join("\n\n")
    end

    def build_labels(project)
      labels = []
      labels << project.automation_label_name if project.automation_on_label_enabled?
      labels << project.generated_label_name if project.auto_add_labels_enabled?
      labels
    end

    def topological_sort(tasks)
      task_count = tasks.size
      in_degree = Array.new(task_count, 0)
      adjacency = Array.new(task_count) { [] }

      tasks.each_with_index do |task, i|
        Array(task[:dependencies]).each do |dep|
          next unless dep >= 0 && dep < task_count

          adjacency[dep] << i
          in_degree[i] += 1
        end
      end

      queue = (0...task_count).select { |i| in_degree[i] == 0 }
      sorted = []

      until queue.empty?
        node = queue.shift
        sorted << node
        adjacency[node].each do |neighbor|
          in_degree[neighbor] -= 1
          queue << neighbor if in_degree[neighbor] == 0
        end
      end

      if sorted.size < task_count
        # Cycle detected — fall back to natural order
        (0...task_count).to_a
      else
        sorted
      end
    end

    def complete_agent_run!(agent_run, created_issues)
      return if created_issues.empty?

      first = created_issues.first
      agent_run.complete!(issue_url: first[:issue_url], issue_number: first[:github_number])

      agent_run.log!(
        "system",
        "Created #{created_issues.size} issues: #{created_issues.map { |i| "##{i[:github_number]}" }.join(', ')}"
      )
    end

    def update_parent_issue(client, project, parent_issue_number, created_issues)
      task_list = created_issues.map { |i| "- [ ] ##{i[:github_number]} — #{i[:title]}" }.join("\n")
      section = "\n\n## Sub-issues\n\n#{task_list}"

      current_issue = client.issue(project.full_name, parent_issue_number)
      current_body = current_issue.body.to_s

      updated_body = if current_body.include?("## Sub-issues")
        current_body.sub(/## Sub-issues\n.*?\z/m, "## Sub-issues\n\n#{task_list}")
      else
        current_body + section
      end

      client.update_issue(project.full_name, parent_issue_number, body: updated_body)

      logger.info(
        message: "agent_execution.parent_issue_updated",
        project_id: project.id,
        parent_issue_number: parent_issue_number,
        sub_issue_count: created_issues.size
      )

      true
    rescue StandardError => e
      logger.warn(
        message: "agent_execution.parent_issue_update_failed",
        project_id: project.id,
        parent_issue_number: parent_issue_number,
        error: e.message
      )
      false
    end

    def sync_issue_record(project, gh_issue)
      Issues::UpsertFromGithub.call(project: project, github_issue: gh_issue)
    rescue => e
      logger.warn(
        message: "agent_execution.sync_multi_issue_failed",
        project_id: project.id,
        issue_number: gh_issue.number,
        error: e.message
      )
      nil
    end
  end
end
