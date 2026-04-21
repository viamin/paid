# frozen_string_literal: true

module Activities
  # Enhances a GitHub issue with knowledge-base-backed implementation context,
  # or asks focused clarifying questions when the issue is not actionable yet.
  class EnhanceIssueActivity < BaseActivity
    activity_name "EnhanceIssue"

    COMMENT_MARKER = "<!-- paid:enhance-issue -->"
    MAX_SEARCH_RESULTS = 10
    MAX_COMMENTS = 50
    MAX_COMMENT_BODY = 50_000
    LLM_TIMEOUT = 120
    DEFAULT_PROVIDER = "claude"
    DEFAULT_MODEL = "claude-sonnet-4-6"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      track_phase(
        agent_run_id: agent_run_id,
        phase_key: "enhance_issue",
        phase_group: "agent",
        agent_run: agent_run
      ) do
        enhance_issue(agent_run)
      end
    end

    private

    def enhance_issue(agent_run)
      agent_run.start!
      project = agent_run.project
      issue = agent_run.issue
      raise ArgumentError, "enhance_issue run requires an issue" unless issue

      client = github_client(project)
      gh_issue = client.issue(project.full_name, issue.github_number)
      comments = client.issue_comments(project.full_name, issue.github_number)
      existing_comment = enhancement_comment(comments)
      return complete_existing(agent_run, existing_comment) if existing_comment && issue.enhance_issue_rounds.zero?

      context = build_context(project, issue)
      response = call_llm(agent_run, prompt_for(project, gh_issue, comments, context))
      parsed = parse_response!(agent_run, response)
      parsed = stop_after_max_rounds(parsed, project, issue)
      comment_body = comment_body_for(parsed)
      gh_comment = client.add_comment(project.full_name, issue.github_number, comment_body)
      label_result = apply_label_state(client, project, issue, parsed)

      track_tokens(agent_run, response)
      agent_run.log!("stdout", comment_body)
      complete_run!(agent_run, paid_state_for(parsed, project, issue))
      ProcessRunQueueJob.perform_later

      logger.info(
        message: "agent_execution.issue_enhanced",
        agent_run_id: agent_run.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        sufficient_context: parsed[:sufficient_context],
        label_applied: label_result[:applied],
        max_rounds_reached: label_result[:max_rounds_reached],
        enhance_issue_rounds: issue.enhance_issue_rounds,
        comment_url: gh_comment.html_url,
        knowledge_results: context[:knowledge_results_count],
        knowledge_sections: context[:bundle_sections]
      )

      {
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        comment_url: gh_comment.html_url,
        sufficient_context: parsed[:sufficient_context],
        label_applied: label_result[:applied],
        max_rounds_reached: label_result[:max_rounds_reached]
      }
    end

    def complete_existing(agent_run, existing_comment)
      complete_run!(agent_run)
      agent_run.log!("system", "Enhancement comment already exists: #{existing_comment.html_url}")
      ProcessRunQueueJob.perform_later

      {
        agent_run_id: agent_run.id,
        issue_number: agent_run.issue.github_number,
        comment_url: existing_comment.html_url,
        sufficient_context: nil,
        already_enhanced: true
      }
    end

    def complete_run!(agent_run, paid_state = "completed")
      agent_run.complete!
      agent_run.issue.update!(paid_state: paid_state) if agent_run.issue
    end

    def build_context(project, issue)
      search = knowledge_search(project, issue)
      bundle = context_bundle(project, issue)

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
      config = project.knowledge_embedding_provider_configuration
      options = { project: project, query: query, mode: "hybrid", limit: MAX_SEARCH_RESULTS }
      options[:api_key] = config.api_key if config&.api_key.present?
      options[:api_base_url] = config.api_base_url if config&.api_base_url.present?

      Knowledge::Search.call(**options)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.enhance_issue_knowledge_search_failed",
        project_id: project.id,
        issue_id: issue.id,
        error_class: e.class.name,
        error: e.message
      )
      { results: [], meta: {} }
    end

    def context_bundle(project, issue)
      Knowledge::ContextBundle::Build.call(issue: issue, project: project)
    rescue Temporalio::Error::CanceledError
      raise
    rescue => e
      logger.warn(
        message: "agent_execution.enhance_issue_context_bundle_failed",
        project_id: project.id,
        issue_id: issue.id,
        error_class: e.class.name,
        error: e.message
      )
      { content: "", sections: [], total_tokens: 0 }
    end

    def call_llm(agent_run, prompt)
      chat_providers(agent_run.project).each do |provider|
        response = AgentHarness.send_message(prompt, **llm_options(provider))
        return response if !response.respond_to?(:success?) || response.success?

        log_failed_response(agent_run, provider, response)
      rescue AgentHarness::Error => e
        logger.warn(
          message: "agent_execution.enhance_issue_provider_failed",
          agent_run_id: agent_run.id,
          provider: provider,
          error_class: e.class.name,
          error: e.message
        )
      end

      raise Temporalio::Error::ApplicationError.new(
        "No LLM provider produced an issue enhancement",
        type: "EnhanceIssueLlmFailed",
        non_retryable: true
      )
    end

    def chat_providers(project)
      setting = project.effective_owner&.settings
      providers = setting ? Knowledge::ProviderSelector.for_chat(user_setting: setting) : []
      providers.presence || [ DEFAULT_PROVIDER ]
    end

    def llm_options(provider)
      options = {
        provider: ProviderSupport.harness_provider_key_for(provider).to_sym,
        timeout: LLM_TIMEOUT,
        dangerous_mode: false,
        tools: :none
      }
      options[:model] = DEFAULT_MODEL if provider == DEFAULT_PROVIDER
      options.merge!(Llm::TextMode.options) if provider == DEFAULT_PROVIDER
      options
    end

    def prompt_for(project, gh_issue, comments, context)
      <<~PROMPT
        You analyze GitHub issues for implementation readiness.

        Decide whether the issue has enough context for an implementation agent.
        Use the issue text, conversation, and knowledge base context. Do not invent
        facts. If requirements are missing or ambiguous, ask specific questions.

        Respond with ONLY valid JSON:
        {
          "sufficient_context": true or false,
          "comment_body": "Markdown comment to post on the issue"
        }

        The comment_body must follow one of these structures:

        If sufficient_context is true:
        ## Implementation context
        ### Relevant files and symbols
        - ...
        ### Architecture notes
        - ...
        ### Suggested approach
        1. ...
        ### Related context
        - ...

        If sufficient_context is false:
        ## Clarifying questions
        1. ...
        ## Current context
        - ...

        Keep the comment concise, actionable, and grounded in the supplied context.

        ## Repository
        #{project.full_name}

        ## Issue
        Title: #{gh_issue.title}
        Number: ##{gh_issue.number}
        Author: #{gh_issue.user&.login}

        #{gh_issue.body.to_s.truncate(20_000)}

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

    def format_search_results(results)
      return "No retrieval results." if results.empty?

      results.map do |result|
        title = result[:title] || result[:identifier] || result[:artifact_type] || "Knowledge result"
        path = result[:path] || result[:scope_path]
        content = result[:content].to_s.truncate(1_500)
        [ "### #{title}", ("Path: #{path}" if path.present?), content ].compact.join("\n")
      end.join("\n\n")
    end

    def parse_response!(agent_run, response)
      output = response.respond_to?(:output) ? response.output.to_s : response.to_s
      parsed = JSON.parse(strip_json_fence(output), symbolize_names: true)
      return parsed if parsed.key?(:sufficient_context) && parsed[:comment_body].present?

      raise JSON::ParserError, "missing sufficient_context or comment_body"
    rescue JSON::ParserError => e
      agent_run.log!("stderr", "Failed to parse enhancement response: #{e.message}")
      raise Temporalio::Error::ApplicationError.new(
        "LLM returned invalid enhancement JSON",
        type: "EnhanceIssueInvalidJson",
        non_retryable: true
      )
    end

    def strip_json_fence(output)
      output.gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip
    end

    def comment_body_for(parsed)
      [ COMMENT_MARKER, parsed[:comment_body].to_s.truncate(MAX_COMMENT_BODY) ].join("\n")
    end

    def stop_after_max_rounds(parsed, project, issue)
      return parsed if parsed[:sufficient_context]
      return parsed unless max_rounds_reached?(project, issue)

      parsed.merge(
        comment_body: <<~COMMENT
          ## Auto-enhancement stopped

          Paid has reached the configured limit of #{project.max_enhance_issue_reevaluation_rounds} enhancement re-evaluation rounds for this issue.

          Manual review is needed before enhancement can continue.

          ## Latest context
          #{parsed[:comment_body]}
        COMMENT
      )
    end

    def enhancement_comment(comments)
      comments.find { |comment| comment.body.to_s.include?(COMMENT_MARKER) }
    end

    def apply_label_state(client, project, issue, parsed)
      if parsed[:sufficient_context]
        add_label(client, project, issue, project.enhance_issue_enhanced_label_name)
        remove_label(client, project, issue, project.enhance_issue_needs_input_label_name)
        merge_local_labels(issue, add: [ project.enhance_issue_enhanced_label_name ],
          remove: [ project.enhance_issue_needs_input_label_name ])
        return { applied: project.enhance_issue_enhanced_label_name, max_rounds_reached: false }
      end

      if max_rounds_reached?(project, issue)
        remove_label(client, project, issue, project.enhance_issue_needs_input_label_name)
        merge_local_labels(issue, remove: [ project.enhance_issue_needs_input_label_name ])
        return { applied: nil, max_rounds_reached: true }
      end

      add_label(client, project, issue, project.enhance_issue_needs_input_label_name)
      remove_label(client, project, issue, project.enhance_issue_enhanced_label_name)
      merge_local_labels(issue, add: [ project.enhance_issue_needs_input_label_name ],
        remove: [ project.enhance_issue_enhanced_label_name ])
      { applied: project.enhance_issue_needs_input_label_name, max_rounds_reached: false }
    end

    def paid_state_for(parsed, project, issue)
      return "completed" if parsed[:sufficient_context]
      return "completed" if max_rounds_reached?(project, issue)

      "needs_input"
    end

    def max_rounds_reached?(project, issue)
      issue.enhance_issue_rounds >= project.max_enhance_issue_reevaluation_rounds
    end

    def add_label(client, project, issue, label)
      client.add_labels_to_issue(project.full_name, issue.github_number, [ label ])
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.enhance_issue_label_add_failed",
        project_id: project.id,
        issue_id: issue.id,
        label: label,
        error_class: e.class.name,
        error: e.message
      )
    end

    def remove_label(client, project, issue, label)
      return unless issue.has_label?(label)

      client.remove_label_from_issue(project.full_name, issue.github_number, label)
    rescue GithubClient::NotFoundError
      nil
    rescue GithubClient::Error => e
      logger.warn(
        message: "agent_execution.enhance_issue_label_remove_failed",
        project_id: project.id,
        issue_id: issue.id,
        label: label,
        error_class: e.class.name,
        error: e.message
      )
    end

    def merge_local_labels(issue, add: [], remove: [])
      labels = (Array(issue.labels) - remove) | add
      issue.update!(labels: labels)
    end

    def track_tokens(agent_run, response)
      return unless response.respond_to?(:tokens) && response.tokens

      TokenUsageTracker.track(
        agent_run: agent_run,
        usage: {
          tokens_input: response.respond_to?(:input_tokens) ? response.input_tokens.to_i : 0,
          tokens_output: response.respond_to?(:output_tokens) ? response.output_tokens.to_i : 0,
          llm_model: response.respond_to?(:model) ? response.model : nil,
          request_type: "agent",
          metadata: { operation: "enhance_issue" }
        }
      )
    end

    def github_client(project)
      project.github_token.client
    end

    def log_failed_response(agent_run, provider, response)
      logger.warn(
        message: "agent_execution.enhance_issue_llm_failed",
        agent_run_id: agent_run.id,
        provider: provider,
        error: response.respond_to?(:error) ? response.error : nil,
        exit_code: response.respond_to?(:exit_code) ? response.exit_code : nil
      )
    end
  end
end
