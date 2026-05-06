# frozen_string_literal: true

module Activities
  # Parses the agent's output to detect a multi-issue decomposition plan.
  #
  # When a create-issue agent determines that a feature should be decomposed
  # into multiple issues with dependency relationships, it emits structured
  # markers in its output:
  #
  #   <!-- multi-issue-plan-start -->
  #   [
  #     {"title": "Add migration", "body": "...", "dependencies": []},
  #     {"title": "Add model",     "body": "...", "dependencies": [0]}
  #   ]
  #   <!-- multi-issue-plan-end -->
  #
  # An optional parent issue reference tells the activity which existing
  # tracking issue to update with a task list of created sub-issues:
  #
  #   <!-- parent-issue: 451 -->
  #
  # Each task's `dependencies` array contains zero-based indices into the
  # plan array. The activity validates the DAG and returns a topologically
  # sorted task list so callers can create issues in dependency order.
  class ParseMultiIssuePlanActivity < BaseActivity
    include Llm::OutputNormalizer

    activity_name "ParseMultiIssuePlan"

    PLAN_PATTERN = /<!--\s*multi-issue-plan-start\s*-->\n?(.*?)\n?<!--\s*multi-issue-plan-end\s*-->/m.freeze
    PARENT_ISSUE_PATTERN = /<!--\s*parent-issue:\s*(\d+)\s*-->/.freeze
    MAX_ISSUES = 20

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      summary = agent_run.agent_summary_with_stderr_fallback
      plan = parse_plan(summary)

      if plan
        # Default parent to the source issue so it becomes the tracking issue
        plan[:parent_issue_number] ||= agent_run.issue&.github_number

        agent_run.log!("system", "Detected multi-issue plan with #{plan[:tasks].size} issues")

        logger.info(
          message: "agent_execution.multi_issue_plan_detected",
          agent_run_id: agent_run_id,
          task_count: plan[:tasks].size,
          parent_issue_number: plan[:parent_issue_number]
        )
      end

      { agent_run_id: agent_run_id, plan: plan }
    end

    private

    def parse_plan(summary)
      return nil if summary.blank?

      raw_json = summary[PLAN_PATTERN, 1]
      return nil if raw_json.blank?

      tasks = parse_tasks(raw_json.strip)
      return nil if tasks.blank?

      parent_issue_number = summary[PARENT_ISSUE_PATTERN, 1]&.to_i

      {
        tasks: tasks,
        parent_issue_number: parent_issue_number
      }
    end

    def parse_tasks(raw)
      cleaned = strip_markdown_fence(raw)
      parsed = JSON.parse(cleaned, symbolize_names: true)

      return nil unless parsed.is_a?(Array) && parsed.any?

      truncated = parsed.first(MAX_ISSUES)
      task_count = truncated.size

      truncated.map.with_index do |task, index|
        return nil unless task.is_a?(Hash) && task[:title].to_s.present?

        deps = Array(task[:dependencies]).select { |d| d.is_a?(Integer) && d >= 0 && d < task_count }

        {
          index: index,
          title: task[:title].to_s.truncate(255),
          body: task[:body].to_s.truncate(50_000),
          dependencies: deps
        }
      end
    rescue JSON::ParserError
      nil
    end
  end
end
