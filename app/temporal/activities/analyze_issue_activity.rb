# frozen_string_literal: true

module Activities
  # Performs a lightweight LLM-based context readiness assessment for a GitHub
  # issue. Called when auto-pick selects an issue on a project with
  # auto_enhance_enabled — evaluates whether the issue + knowledge base provide
  # enough context to start a create_pr run.
  #
  # This is a direct LLM call — no container provisioning or repo cloning.
  class AnalyzeIssueActivity < BaseActivity
    activity_name "AnalyzeIssue"

    LLM_TIMEOUT = 90
    DEFAULT_PROVIDER = "claude"
    DEFAULT_MODEL = "claude-sonnet-4-6"
    MAX_SEARCH_RESULTS = 10
    MAX_COMMENTS = 50

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      track_phase(
        agent_run_id: agent_run_id,
        phase_key: "analyze_issue",
        phase_group: "agent",
        agent_run: agent_run
      ) do
        analyze_issue(agent_run)
      end
    end

    private

    def analyze_issue(agent_run)
      agent_run.start!
      project = agent_run.project
      issue = agent_run.issue
      raise ArgumentError, "analyze_issue run requires an issue" unless issue
      ensure_trusted_issue!(issue)

      client = github_client(project)
      comments = trusted_comments(project, client.issue_comments(project.full_name, issue.github_number))

      context = build_context(agent_run, project, issue)
      response = call_llm(agent_run, prompt_for(project, issue, comments, context))
      parsed = parse_response!(agent_run, response)

      track_tokens(agent_run, response)
      agent_run.log!("stdout", parsed.to_json)
      complete_run!(agent_run, "analyzed")
      ProcessRunQueueJob.perform_later

      logger.info(
        message: "agent_execution.issue_analyzed",
        agent_run_id: agent_run.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        sufficient_context: parsed[:sufficient_context],
        missing_context_areas: parsed[:missing_context_areas],
        knowledge_results: context[:knowledge_results_count],
        knowledge_sections: context[:bundle_sections]
      )

      {
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        sufficient_context: parsed[:sufficient_context],
        reasoning: parsed[:reasoning],
        missing_context_areas: parsed[:missing_context_areas]
      }
    end

    def complete_run!(agent_run, paid_state = "analyzed")
      agent_run.complete!
      agent_run.issue.update!(paid_state: paid_state) if agent_run.issue
    end

    def build_context(agent_run, project, issue)
      search = knowledge_search(project, issue)
      bundle = context_bundle(agent_run, project, issue)

      {
        search_results: search[:results],
        knowledge_results_count: search[:results].size,
        bundle_content: bundle[:content],
        bundle_sections: bundle[:sections],
        bundle_tokens: bundle[:total_tokens]
      }
    end

    def knowledge_search(project, issue)
      query = "#{issue.title}\n\n#{issue.body.to_s.truncate(2_000)}"

      Knowledge::Search.call(project: project, query: query, mode: "hybrid", limit: MAX_SEARCH_RESULTS)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.analyze_issue_knowledge_search_failed",
        project_id: project.id,
        issue_id: issue.id,
        error_class: e.class.name,
        error: e.message
      )
      { results: [], meta: {} }
    end

    def context_bundle(agent_run, project, issue)
      Knowledge::ContextBundle::Build.call(issue: issue, project: project, agent_run: agent_run)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.analyze_issue_context_bundle_failed",
        project_id: project.id,
        issue_id: issue.id,
        error_class: e.class.name,
        error: e.message
      )
      { content: "", sections: [], total_tokens: 0 }
    end

    CLI_STREAMING_EVENT_PREFIX = '{"type":"session.'

    def call_llm(agent_run, prompt)
      chat_providers(agent_run.project).each do |provider|
        response = AgentHarness.send_message(prompt, **llm_options(provider))
        next if response_failed_or_cli_leak?(response, agent_run, provider)

        return response
      rescue AgentHarness::Error => e
        logger.warn(
          message: "agent_execution.analyze_issue_provider_failed",
          agent_run_id: agent_run.id,
          provider: provider,
          error_class: e.class.name,
          error: e.message
        )
      end

      raise Temporalio::Error::ApplicationError.new(
        "No LLM provider produced an issue analysis",
        type: "AnalyzeIssueLlmFailed",
        non_retryable: true
      )
    end

    def response_failed_or_cli_leak?(response, agent_run, provider)
      if response.respond_to?(:success?) && !response.success?
        log_failed_response(agent_run, provider, response)
        return true
      end

      output = response.respond_to?(:output) ? response.output.to_s : ""
      if cli_streaming_only?(output)
        logger.warn(
          message: "agent_execution.analyze_issue_cli_streaming_leak",
          agent_run_id: agent_run.id,
          provider: provider,
          output_prefix: output.truncate(200)
        )
        agent_run.log!("stderr", "LLM returned CLI streaming event instead of analysis: #{output.truncate(500)}")
        return true
      end

      false
    end

    def cli_streaming_only?(output)
      return false unless output.start_with?(CLI_STREAMING_EVENT_PREFIX)
      !output.include?('"result"')
    end

    def chat_providers(project)
      setting = project.effective_owner&.settings
      providers = setting ? Knowledge::ProviderSelector.for_chat(user_setting: setting) : []
      providers.presence || [ DEFAULT_PROVIDER ]
    end

    def llm_options(provider)
      options = {
        provider: RunnerSupport.harness_runner_key_for(provider).to_sym,
        timeout: LLM_TIMEOUT,
        dangerous_mode: false,
        tools: :none
      }
      options[:model] = DEFAULT_MODEL if provider == DEFAULT_PROVIDER
      options.merge!(Llm::TextMode.options) if provider == DEFAULT_PROVIDER
      options
    end

    def prompt_for(project, issue, comments, context)
      <<~PROMPT
        You are an issue readiness assessor. Evaluate whether the given GitHub issue
        has enough context for an autonomous implementation agent to start working.

        Consider:
        - Does the issue title and description provide enough detail to start implementation?
        - Does the knowledge base contain relevant context (architecture, patterns, dependencies)?
        - Are there ambiguities that require human clarification?
        - Is the acceptance criteria clear enough for an agent to work autonomously?

        Respond with ONLY valid JSON:
        {
          "sufficient_context": true or false,
          "reasoning": "Brief explanation of your assessment",
          "missing_context_areas": ["area1", "area2"]
        }

        When sufficient_context is true, missing_context_areas should be an empty array.
        When sufficient_context is false, list the specific areas that need clarification.

        ## Repository
        #{project.full_name}

        ## Issue
        Title: #{issue.title}
        Number: ##{issue.github_number}
        Author: #{issue.github_creator_login}

        #{issue.body.to_s.truncate(20_000)}

        ## Conversation
        #{format_comments(comments)}

        ## Retrieval Results
        #{format_search_results(context[:search_results])}

        #{context[:bundle_content].presence || "## Codebase Context\nNo context bundle entries were available."}
      PROMPT
    end

    def format_comments(comments)
      relevant = comments.last(MAX_COMMENTS)
      return "No comments." if relevant.empty?

      relevant.map do |comment|
        author = comment.user&.login || "unknown"
        created = comment.created_at || "unknown time"
        body = comment.body.to_s.truncate(2_000)
        "### #{author} at #{created}\n#{body}"
      end.join("\n\n")
    end

    def trusted_comments(project, comments)
      comments.select { |comment| project.trusted_github_user?(comment.user&.login) }
    end

    def ensure_trusted_issue!(issue)
      return if issue.trusted?

      logger.warn(
        message: "agent_execution.analyze_issue_untrusted_issue_rejected",
        issue_id: issue.id,
        creator: issue.github_creator_login
      )
      raise Temporalio::Error::ApplicationError.new(
        "Cannot analyze issue from untrusted user: #{issue.github_creator_login}",
        type: "UntrustedIssue",
        non_retryable: true
      )
    end

    def format_search_results(results)
      return "No retrieval results." if results.empty?

      results.map do |result|
        title = result[:title] || result[:identifier] || result[:artifact_type] || "Knowledge result"
        path = result[:path] || result[:scope_path]
        content = result[:content].to_s.truncate(1_500)
        [ title && "### #{title}", ("Path: #{path}" if path.present?), content ].compact.join("\n")
      end.join("\n\n")
    end

    def parse_response!(agent_run, response)
      output = response.respond_to?(:output) ? response.output.to_s : response.to_s
      parsed = extract_analysis_json(output)

      unless parsed.key?(:sufficient_context) && parsed.key?(:reasoning)
        raise JSON::ParserError, "missing sufficient_context or reasoning"
      end

      parsed[:missing_context_areas] ||= []
      parsed
    rescue JSON::ParserError => e
      agent_run.log!("stderr", "Failed to parse analysis response: #{e.message}")
      agent_run.log!("stderr", "Raw output: #{output.truncate(2000)}")
      raise Temporalio::Error::ApplicationError.new(
        "LLM returned invalid analysis JSON",
        type: "AnalyzeIssueInvalidJson",
        non_retryable: true
      )
    end

    def extract_analysis_json(output)
      stripped = strip_json_fence(output)
      JSON.parse(stripped, symbolize_names: true)
    rescue JSON::ParserError
      result_payload = extract_result_from_jsonl(output)
      raise JSON::ParserError, "no valid analysis JSON found" unless result_payload

      JSON.parse(result_payload, symbolize_names: true)
    end

    def extract_result_from_jsonl(output)
      output.each_line do |line|
        next unless line.lstrip.start_with?("{")
        parsed = JSON.parse(line, symbolize_names: true)
        if parsed.is_a?(Hash) && parsed[:type] == "result" && parsed[:result].is_a?(String)
          return parsed[:result]
        end
      rescue JSON::ParserError
        next
      end
      nil
    end

    def strip_json_fence(output)
      output.gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip
    end

    def track_tokens(agent_run, response)
      return unless response.respond_to?(:tokens) && response.tokens

      TokenUsageTracker.track(
        tracked_run: agent_run,
        usage: {
          tokens_input: response.respond_to?(:input_tokens) ? response.input_tokens.to_i : 0,
          tokens_output: response.respond_to?(:output_tokens) ? response.output_tokens.to_i : 0,
          llm_model: response.respond_to?(:model) ? response.model : nil,
          request_type: "agent",
          metadata: { operation: "analyze_issue" }
        }
      )
    end

    def github_client(project)
      project.client
    end

    def log_failed_response(agent_run, provider, response)
      logger.warn(
        message: "agent_execution.analyze_issue_llm_failed",
        agent_run_id: agent_run.id,
        provider: provider,
        error: response.respond_to?(:error) ? response.error : nil,
        exit_code: response.respond_to?(:exit_code) ? response.exit_code : nil
      )
    end
  end
end
