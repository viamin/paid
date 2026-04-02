# frozen_string_literal: true

module Activities
  # Uses LLM to analyze a feature request and decompose it into smaller,
  # independently-implementable sub-tasks. Considers codebase knowledge
  # for informed decomposition.
  class DecomposeFeatureActivity < BaseActivity
    include Llm::OutputNormalizer

    activity_name "DecomposeFeature"

    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 60
    MAX_TASKS = 20

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      knowledge_context = input[:knowledge_context] || {}

      project = Project.find(project_id)
      issue = project.issues.find(issue_id)

      tasks = decompose(issue, knowledge_context)

      logger.info(
        message: "planning.decomposition_complete",
        project_id: project_id,
        issue_id: issue_id,
        task_count: tasks.size
      )

      { tasks: tasks }
    end

    private

    def decompose(issue, context)
      prompt = build_prompt(issue, context)
      response = AgentHarness.send_message(prompt, provider: :claude, model: DEFAULT_MODEL, timeout: TIMEOUT)

      unless response.success?
        raise Temporalio::Error::ApplicationError.new(
          "LLM decomposition failed: #{response.error}",
          type: "DecompositionFailed",
          non_retryable: true
        )
      end

      parse_tasks(response.output)
    end

    def build_prompt(issue, context)
      knowledge_section = build_knowledge_section(context[:knowledge_snippets])

      <<~PROMPT.strip
        You are a software architect. Analyze the following feature request and decompose it into smaller, independently-implementable sub-tasks.

        ## Feature Request
        **Title:** #{issue.title}
        **Description:**
        #{issue.body.to_s.truncate(8000)}

        #{knowledge_section}

        ## Instructions
        - Each sub-task should be independently implementable and testable
        - Order tasks by dependency (tasks that others depend on come first)
        - Mark tasks that can be worked on in parallel (no dependencies between them)
        - If this is a simple feature that doesn't need decomposition, return a single task
        - Keep task descriptions clear and actionable
        - Include acceptance criteria for each task
        - Maximum #{MAX_TASKS} tasks

        ## Output Format
        Respond with ONLY a JSON array. Each element must have these fields:
        - "title": concise task title (string)
        - "description": detailed description with acceptance criteria (string)
        - "dependencies": array of task indices (0-based) this task depends on (array of integers)
        - "parallel_group": integer grouping tasks that can run in parallel (tasks with the same group number have no dependencies on each other)

        Example:
        [
          {"title": "Add database migration for X", "description": "Create migration to add...", "dependencies": [], "parallel_group": 0},
          {"title": "Implement model for X", "description": "Create ActiveRecord model...", "dependencies": [0], "parallel_group": 1},
          {"title": "Add API endpoint for X", "description": "Create controller action...", "dependencies": [1], "parallel_group": 2}
        ]
      PROMPT
    end

    def build_knowledge_section(snippets)
      return "" if snippets.blank?

      formatted = snippets.map { |s| "- **#{s[:title]}**: #{s[:content]}" }.join("\n")
      <<~SECTION
        ## Codebase Context
        The following knowledge from the codebase may help inform your decomposition:
        #{formatted}
      SECTION
    end

    def parse_tasks(output)
      cleaned = strip_markdown_fence(output.to_s.strip)
      tasks = JSON.parse(cleaned, symbolize_names: true)

      unless tasks.is_a?(Array)
        raise Temporalio::Error::ApplicationError.new(
          "LLM returned non-array response",
          type: "DecompositionFailed",
          non_retryable: true
        )
      end

      truncated_tasks = tasks.first(MAX_TASKS)
      task_count = truncated_tasks.length

      truncated_tasks.map.with_index do |task, index|
        unless task.is_a?(Hash)
          raise Temporalio::Error::ApplicationError.new(
            "LLM returned non-Hash element at index #{index}: #{task.class}",
            type: "DecompositionFailed",
            non_retryable: true
          )
        end

        {
          index: index,
          title: task[:title].to_s.truncate(255),
          description: task[:description].to_s.truncate(5000),
          dependencies: Array(task[:dependencies]).select { |d| d.is_a?(Integer) && d >= 0 && d < task_count },
          parallel_group: task[:parallel_group].is_a?(Integer) ? task[:parallel_group] : index
        }
      end
    rescue JSON::ParserError => e
      raise Temporalio::Error::ApplicationError.new(
        "Failed to parse LLM decomposition output: #{e.message}",
        type: "DecompositionFailed",
        non_retryable: true
      )
    end
  end
end
