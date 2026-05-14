# frozen_string_literal: true

module Activities
  # Uses LLM to analyze a feature request and decompose it into smaller,
  # independently-implementable sub-tasks. Considers codebase knowledge
  # for informed decomposition.
  class DecomposeFeatureActivity < BaseActivity
    include Llm::OutputNormalizer

    activity_name "DecomposeFeature"

    DEFAULT_MODEL = "claude-sonnet-4-6"
    POLICY_PROMPT_SOURCE = "policy_service"
    TIMEOUT = 60
    MAX_TASKS = 20

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      knowledge_context = input[:knowledge_context] || {}
      workflow_name = input[:workflow_name]
      workflow_id = input[:workflow_id]

      project = Project.find(project_id)
      issue = project.issues.find(issue_id)
      prompt_data = nil
      policy_context = default_policy_context

      policy_result, policy_context = decompose_with_policy_service(
        project: project,
        issue: issue,
        coordination_policy: input[:coordination_policy]
      )
      if policy_result
        log_decomposition_strategy_decision(
          project: project,
          issue: issue,
          workflow_name: workflow_name,
          workflow_id: workflow_id,
          input_context: knowledge_context,
          tasks: policy_result[:tasks],
          prompt_source: policy_result[:prompt_source],
          policy_context: policy_context,
          outcome: policy_strategy_outcome_for(policy_result)
        )
        return with_policy_provenance(policy_result)
      end

      prompt_data = render_prompt(issue, knowledge_context)
      tasks = decompose(prompt_data[:prompt])

      logger.info(
        message: "planning.decomposition_complete",
        project_id: project_id,
        issue_id: issue_id,
        task_count: tasks.size,
        prompt_source: prompt_data[:prompt_source]
      )

      log_decomposition_strategy_decision(
        project: project,
        issue: issue,
        workflow_name: workflow_name,
        workflow_id: workflow_id,
        input_context: knowledge_context,
        tasks: tasks,
        prompt_source: prompt_data[:prompt_source],
        policy_context: policy_context,
        outcome: llm_strategy_outcome_for(policy_context)
      )

      with_policy_provenance(
        {
        tasks: tasks,
        prompt_source: prompt_data[:prompt_source],
        policy_metadata: policy_context[:metadata]
      }
      )
    rescue Temporalio::Error::ApplicationError => e
      log_decomposition_strategy_decision(
        project: project,
        issue: issue,
        workflow_name: workflow_name,
        workflow_id: workflow_id,
        input_context: knowledge_context,
        tasks: [],
        prompt_source: prompt_data&.dig(:prompt_source),
        policy_context: policy_context,
        outcome: llm_failure_outcome_for(policy_context),
        error_details: {
          error_class: e.class.name,
          error_message: e.message
        }
      )
      raise application_error_with_policy_provenance(e, policy_context)
    end

    private

    def decompose_with_policy_service(project:, issue:, coordination_policy:)
      context = default_policy_context.merge(attempted: true)
      scope_result = ScopeAnalysis::Analyze.call(text: issue.body)
      context[:scope_analysis] = {
        should_decompose: scope_result.should_decompose?,
        confidence: scope_result.confidence,
        sub_components: scope_result.sub_components
      }
      decomposition_result = DecompositionService.call(
        title: issue.title,
        description: issue.body,
        sub_components: scope_result.sub_components,
        project: project,
        account: project.account,
        policy_override: coordination_policy
      )
      context[:source] = decomposition_result.policy_source
      context[:present] = policy_source_present?(decomposition_result.policy_source)
      context[:skip_reason] = decomposition_result.skip_reason
      context[:metadata] = result_policy_metadata(decomposition_result)

      return [ nil, context ] unless use_policy_service_result?(decomposition_result)

      tasks = serialize_policy_tasks(decomposition_result.tasks)
      logger.info(
        message: "planning.decomposition_complete",
        project_id: project.id,
        issue_id: issue.id,
        task_count: tasks.size,
        prompt_source: POLICY_PROMPT_SOURCE,
        policy_source: decomposition_result.policy_source,
        skip_reason: decomposition_result.skip_reason
      )

      [ {
        tasks: tasks,
        prompt_source: POLICY_PROMPT_SOURCE,
        policy_source: decomposition_result.policy_source,
        skip_reason: decomposition_result.skip_reason,
        policy_metadata: result_policy_metadata(decomposition_result)
      }, context ]
    rescue StandardError => e
      context[:error_details] = {
        error_class: e.class.name,
        error_message: e.message
      }
      logger.warn(
        message: "planning.policy_decomposition_failed",
        error_class: e.class.name,
        error: e.message
      )
      [ nil, context ]
    end

    def decompose(prompt)
      response = AgentHarness.send_message(
        prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **Llm::TextMode.options
      )

      unless response.success?
        raise Temporalio::Error::ApplicationError.new(
          "LLM decomposition failed: #{response.error}",
          type: "DecompositionFailed",
          non_retryable: true
        )
      end

      parse_tasks(response.output)
    end

    PROMPT_SLUG = "planning.decompose_feature"

    # Fallback used only if the seeded prompt is missing or deactivated.
    # The active template lives in db/seeds/prompts.rb under PROMPT_SLUG.
    FALLBACK_PROMPT = <<~PROMPT
      You are a software architect. Analyze the following feature request and decompose it into smaller, independently-implementable sub-tasks.

      ## Feature Request
      **Title:** {{title}}
      **Description:**
      {{body}}

      {{knowledge_section}}

      ## Instructions
      - Each sub-task should be independently implementable and testable
      - Order tasks by dependency (tasks that others depend on come first)
      - Mark tasks that can be worked on in parallel (no dependencies between them)
      - If this is a simple feature that doesn't need decomposition, return a single task
      - Keep task descriptions clear and actionable
      - Include acceptance criteria for each task
      - Maximum {{max_tasks}} tasks

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

    def render_prompt(issue, context)
      vars = {
        title: issue.title,
        body: issue.body.to_s.truncate(8000),
        knowledge_section: build_knowledge_section(context[:knowledge_snippets]),
        max_tasks: MAX_TASKS
      }

      prompt = Prompt.resolve(PROMPT_SLUG, project: issue.project)
      version = prompt&.current_version

      if version
        { prompt: version.render(vars).strip, prompt_source: "active_prompt" }
      else
        logger.warn(
          message: "planning.decomposition_prompt_fallback",
          project_id: issue.project_id,
          issue_id: issue.id,
          prompt_slug: PROMPT_SLUG
        )
        {
          prompt: Prompts::Render.interpolate(FALLBACK_PROMPT, vars).strip,
          prompt_source: "fallback_prompt"
        }
      end
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

    def use_policy_service_result?(result)
      result.decomposed? || (result.skipped? && !%w[defaults fallback].include?(result.policy_source))
    end

    def serialize_policy_tasks(tasks)
      parallel_groups = {}

      tasks.map do |task|
        dependencies = Array(task[:deps])
        parallel_group = parallel_groups.fetch(dependencies) do
          parallel_groups[dependencies] = parallel_groups.size
        end

        {
          index: task[:index],
          title: task[:title],
          description: task[:description],
          dependencies: dependencies,
          parallel_group: parallel_group,
          scope: task[:scope]
        }
      end
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

    def default_policy_context
      {
        attempted: false,
        present: false,
        source: nil,
        skip_reason: nil,
        metadata: {},
        error_details: {},
        scope_analysis: {}
      }
    end

    def result_policy_metadata(decomposition_result)
      policy_applied = decomposition_result.policy_applied.to_h.deep_stringify_keys

      {
        policy_source: decomposition_result.policy_source,
        skip_reason: decomposition_result.skip_reason,
        policy_key: policy_applied["policy_key"],
        coordination_policy_id: policy_applied["coordination_policy_id"],
        coordination_policy_version_id: policy_applied["coordination_policy_version_id"],
        coordination_policy_version: policy_applied["coordination_policy_version"]
      }.compact
    end

    def with_policy_provenance(result)
      payload = result.to_h.deep_symbolize_keys
      metadata = payload[:policy_metadata]
      return payload unless metadata.respond_to?(:to_h)

      normalized_metadata = metadata.to_h.deep_symbolize_keys

      payload.merge(
        policy_metadata: normalized_metadata,
        **normalized_metadata
      )
    end

    def application_error_with_policy_provenance(error, policy_context)
      metadata = policy_context[:metadata].to_h.deep_symbolize_keys
      return error if metadata.empty?

      existing_details = Array(error.details)
      provenance_details = existing_details.find do |detail|
        detail.is_a?(Hash) && (detail.key?(:policy_metadata) || detail.key?("policy_metadata"))
      end
      return error if provenance_details

      Temporalio::Error::ApplicationError.new(
        error.message,
        *existing_details,
        { policy_metadata: metadata },
        type: error.type,
        non_retryable: error.non_retryable,
        next_retry_delay: error.next_retry_delay,
        category: error.category
      )
    end

    def log_decomposition_strategy_decision(project:, issue:, workflow_name:, workflow_id:, input_context:, tasks:,
      prompt_source:, policy_context:, outcome:, error_details: {})
      return if workflow_name.blank? || workflow_id.blank?

      Orchestration::DecompositionDecisions::Log.call(
        project_id: project.id,
        issue_id: issue.id,
        decision_key: decomposition_decision_key(workflow_id, error_details),
        workflow_name: workflow_name,
        workflow_id: workflow_id,
        decision_type: "decomposition_strategy",
        outcome: outcome,
        input_context: input_context.merge(
          scope_analysis: policy_context[:scope_analysis],
          coordination_policy_present: policy_context[:present]
        ),
        plan_data: { tasks: tasks },
        error_details: error_details,
        metadata: {
          prompt_source: prompt_source,
          workflow_step: "decompose_feature",
          activity_boundaries: [ self.class.name ],
          policy_attempted: policy_context[:attempted],
          policy_source: policy_context[:source],
          skip_reason: policy_context[:skip_reason],
          policy_error: policy_context[:error_details]
        }
      )
    rescue StandardError => e
      logger.warn(
        message: "planning.decomposition_strategy_log_failed",
        project_id: project.id,
        issue_id: issue.id,
        workflow_id: workflow_id,
        error_class: e.class.name,
        error: e.message
      )
    end

    def decomposition_decision_key(workflow_id, error_details)
      suffix = error_details.present? ? "failure" : "final"
      "#{workflow_id}:decomposition_strategy:#{suffix}"
    end

    def policy_strategy_outcome_for(policy_result)
      return "policy_skipped" if policy_result[:skip_reason].present?

      "policy_decomposed"
    end

    def policy_source_present?(policy_source)
      policy_source.present? && !%w[defaults fallback].include?(policy_source)
    end

    def llm_strategy_outcome_for(policy_context)
      return "llm_fallback_after_policy_failure" if policy_context[:error_details].present?

      "llm_generated_plan"
    end

    def llm_failure_outcome_for(policy_context)
      return "llm_fallback_failed_after_policy_failure" if policy_context[:error_details].present?

      "llm_decomposition_failed"
    end
  end
end
