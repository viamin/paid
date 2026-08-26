# frozen_string_literal: true

module Activities
  # Performs a lightweight LLM-based context readiness assessment for a GitHub
  # issue. Called when auto-pick selects an issue on a project with
  # auto_enhance_enabled — evaluates whether the issue + knowledge base provide
  # enough context to start a create_pr run.
  #
  # This is a direct LLM call — no container provisioning or repo cloning.
  class AnalyzeIssueActivity < BaseActivity
    include Llm::OutputNormalizer

    activity_name "AnalyzeIssue"

    LLM_TIMEOUT = 90
    # Used only to pin a model and opt into the HTTP text transport when the
    # resolved provider happens to be claude. The provider itself is no longer
    # forced — selection comes from the user's issue-analysis / chat runners.
    CLAUDE_RUNNER = "claude"
    CLAUDE_MODEL = "claude-sonnet-4-6"
    MAX_SEARCH_RESULTS = 10
    MAX_COMMENTS = 50
    KNOWLEDGE_SEARCH_BUDGET = 60
    CONTEXT_BUNDLE_BUDGET = 60

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
      issue.clear_issue_analysis_backoff!
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
      # @spec KNOWLEDGE-005
      search = track_issue_analysis_phase(
        agent_run: agent_run,
        phase_key: "analyze_issue_knowledge_search",
        budget_seconds: KNOWLEDGE_SEARCH_BUDGET
      ) do
        knowledge_search(agent_run, project, issue)
      end
      bundle = track_issue_analysis_phase(
        agent_run: agent_run,
        phase_key: "analyze_issue_context_bundle",
        budget_seconds: CONTEXT_BUNDLE_BUDGET
      ) do
        context_bundle(agent_run, project, issue)
      end

      {
        search_results: search[:results],
        knowledge_results_count: search[:results].size,
        bundle_content: bundle[:content],
        bundle_sections: bundle[:sections],
        bundle_tokens: bundle[:total_tokens]
      }
    end

    def knowledge_search(agent_run, project, issue)
      query = "#{issue.title}\n\n#{issue.body.to_s.truncate(2_000)}"

      Knowledge::Search.call(
        project: project,
        query: query,
        mode: "hybrid",
        limit: MAX_SEARCH_RESULTS,
        agent_run_id: agent_run.id
      )
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
      Knowledge::ContextBundle::Build.call(
        issue: issue,
        project: project,
        agent_run: agent_run,
        agent_run_id: agent_run.id
      )
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

    # @spec ISSUE-ANALYSIS-003 ISSUE-ANALYSIS-006 ISSUE-ANALYSIS-007
    def call_llm(agent_run, prompt)
      user_setting = owner_user_setting(agent_run.project)
      providers = chat_providers(agent_run.project)
      rate_limited_count = 0
      earliest_reset_at = nil

      providers.each_with_index do |provider, index|
        response = track_issue_analysis_phase(
          agent_run: agent_run,
          phase_key: "analyze_issue_provider_attempt",
          budget_seconds: LLM_TIMEOUT,
          metadata: { provider: provider, attempt: index + 1, heartbeat_active: true }
        ) do
          with_periodic_heartbeat(
            "analyze_issue.provider_attempt",
            agent_run_id: agent_run.id,
            provider: provider,
            attempt: index + 1
          ) do
            AgentHarness.send_message(prompt, **llm_options(provider))
          end
        end
        if response_failed?(response, agent_run, provider)
          reset_at = record_response_failure(user_setting, provider, response)
          if reset_at
            rate_limited_count += 1
            earliest_reset_at = [ earliest_reset_at, reset_at ].compact.min
          end
          next
        end

        record_runner_success(user_setting, provider)
        return response
      rescue AgentHarness::RateLimitError => e
        rate_limited_count += 1
        earliest_reset_at = [ earliest_reset_at, e.reset_time ].compact.min
        record_runner_rate_limit(user_setting, provider, reset_at: e.reset_time)
        log_provider_failure(agent_run, provider, e)
      rescue AgentHarness::AuthenticationError => e
        record_runner_auth_failure(user_setting, provider)
        log_provider_failure(agent_run, provider, e)
      rescue AgentHarness::Error => e
        record_runner_failure(user_setting, provider)
        log_provider_failure(agent_run, provider, e)
      end

      raise_llm_failure!(agent_run, providers, rate_limited_count, earliest_reset_at)
    end

    # @spec ISSUE-ANALYSIS-006
    # When every attempted provider failed specifically because it is
    # rate-limited, this is a transient outage rather than a permanent
    # failure: park the run in "rate_limited" (mirrors the create_pr runner
    # path) so StaleRunDetectorJob re-queues it once the window clears,
    # instead of failing the issue analysis permanently. Any other failure
    # mix (including "no candidates at all") keeps the existing non-retryable
    # AnalyzeIssueLlmFailed error.
    def raise_llm_failure!(agent_run, providers, rate_limited_count, reset_at)
      if providers.any? && rate_limited_count == providers.size
        agent_run.rate_limit!(
          error: "All LLM providers rate limited: #{providers.join(', ')}",
          reset_at: reset_at || 60.seconds.from_now
        )
        raise Temporalio::Error::ApplicationError.new(
          "All LLM providers are currently rate limited",
          type: "RateLimit"
        )
      end

      raise Temporalio::Error::ApplicationError.new(
        issue_analysis_provider_exhaustion_message(providers),
        type: "AnalyzeIssueLlmFailed",
        non_retryable: true
      )
    end

    def issue_analysis_provider_exhaustion_message(providers) # @spec ISSUE-ANALYSIS-010
      suffix = providers.any? ? ": #{providers.join(', ')}" : ""
      "All issue-analysis providers exhausted#{suffix}"
    end

    def response_failed?(response, agent_run, provider)
      return false unless response.respond_to?(:success?) && !response.success?

      log_failed_response(agent_run, provider, response)
      true
    end

    # @spec ISSUE-ANALYSIS-007 ISSUE-ANALYSIS-009
    # A response with success? == false is not an exception, so it never hit
    # the rescue clauses below and the provider's circuit breaker never
    # learned about the failure (#3639). Classify the response the same way
    # a raised error would be classified, so rate-limit- and auth-shaped
    # responses get their specialized state transition instead of counting
    # as a generic failure. Returns the rate-limit reset time when the
    # response was classified as rate-limited, otherwise nil.
    def record_response_failure(user_setting, provider, response)
      case classify_response_error(response)
      when :rate_limited
        reset_at = RunnerSupport.rate_limit_reset_at(RunnerSupport.harness_for(provider), response.error)
        record_runner_rate_limit(user_setting, provider, reset_at: reset_at)
        reset_at
      when :auth_expired
        record_runner_auth_failure(user_setting, provider)
        nil
      else
        record_runner_failure(user_setting, provider)
        nil
      end
    end

    def classify_response_error(response)
      return :unknown if response.error.blank?

      AgentHarness::ErrorTaxonomy.classify_message(response.error)
    end

    def log_provider_failure(agent_run, provider, error)
      logger.warn(
        message: "agent_execution.analyze_issue_provider_failed",
        agent_run_id: agent_run.id,
        provider: provider,
        error_class: error.class.name,
        error: error.message
      )
    end

    # @spec ISSUE-ANALYSIS-001 ISSUE-ANALYSIS-002 ISSUE-ANALYSIS-008
    def chat_providers(project)
      setting = owner_user_setting(project) or return []

      # Primary: the owner's explicit issue-analysis runner selection.
      providers = Knowledge::ProviderSelector.for_issue_analysis(user_setting: setting)
      return providers if providers.any?

      # Broaden to every chat-capable runner the owner has, applying the same
      # circuit-breaker / rate-limit availability filter. An empty list makes
      # call_llm fail loudly rather than masking the outage by forcing a
      # provider the user never configured (the old Anthropic-only default).
      # Economical runners are tried first so a lightweight assessment call
      # doesn't burn tokens on a heavy-exploration runner.
      available = Knowledge::ProviderSelector.available_chat_runner_keys(user_setting: setting)
      RunnerSupport.lean_first(available)
    end

    def owner_user_setting(project)
      project.effective_owner&.settings
    end

    # @spec ISSUE-ANALYSIS-007
    def record_runner_rate_limit(user_setting, provider, reset_at:)
      runner_state_for(user_setting, provider)&.mark_rate_limited!(reset_at: reset_at)
    end

    # @spec ISSUE-ANALYSIS-007
    def record_runner_failure(user_setting, provider)
      return unless user_setting

      runner_state_for(user_setting, provider)&.record_failure!(
        threshold: user_setting.circuit_breaker_failure_threshold,
        decay_window: user_setting.circuit_breaker_timeout_seconds
      )
    end

    # @spec ISSUE-ANALYSIS-009
    # Authentication failures are deterministic, not transient — retrying the
    # same provider will not succeed until the owner reconnects it. Open the
    # circuit immediately (threshold: 1) instead of waiting for the generic
    # failure count to accumulate.
    def record_runner_auth_failure(user_setting, provider)
      return unless user_setting

      runner_state_for(user_setting, provider)&.record_failure!(
        threshold: 1,
        decay_window: user_setting.circuit_breaker_timeout_seconds
      )
    end

    def record_runner_success(user_setting, provider)
      runner_state_for(user_setting, provider)&.record_success!
    end

    def runner_state_for(user_setting, provider)
      return unless user_setting

      user_setting.user.runner_states.find_or_create_by!(runner_name: provider.to_s) do |state|
        state.circuit_state = "closed"
        state.failure_count = 0
      end
    end

    # @spec ISSUE-ANALYSIS-002
    def llm_options(provider)
      options = {
        provider: RunnerSupport.harness_runner_key_for(provider).to_sym,
        timeout: LLM_TIMEOUT,
        dangerous_mode: false,
        tools: :none
      }
      # Pin a model and opt into text mode only for claude; other providers use
      # their harness default model and CLI transport.
      options[:model] = CLAUDE_MODEL if provider == CLAUDE_RUNNER
      options.merge!(Llm::TextMode.options) if provider == CLAUDE_RUNNER
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

    # @spec ISSUE-ANALYSIS-004
    def trusted_comments(project, comments)
      comments.select { |comment| project.trusted_github_user?(comment.user&.login) }
    end

    # @spec ISSUE-ANALYSIS-004
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

    # @spec ISSUE-ANALYSIS-005
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
      parse_analysis_candidate(output) ||
        raise(JSON::ParserError, "no analysis JSON object found")
    end

    def parse_analysis_candidate(output)
      analysis_json_candidates(output).each do |candidate|
        parsed = JSON.parse(candidate, symbolize_names: true)
        return parsed if parsed.is_a?(Hash) && parsed.key?(:sufficient_context) && parsed.key?(:reasoning)
      rescue JSON::ParserError
        next
      end

      nil
    end

    def analysis_json_candidates(output)
      stripped = output.to_s.strip
      candidates = [ strip_markdown_fence(stripped) ]
      candidates.concat(stripped.scan(/```(?:json)?\s*(.*?)\s*```/m).flatten)
      candidates << embedded_json_object(stripped)
      candidates.compact.uniq
    end

    def embedded_json_object(output)
      start = output.index("{")
      finish = output.rindex("}")
      return unless start && finish && finish > start

      output[start..finish]
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

    def track_issue_analysis_phase(agent_run:, phase_key:, budget_seconds:, metadata: {})
      started_at = Time.current
      base_metadata = metadata.merge(
        phase_key: phase_key,
        phase_label: AgentRunPhase::PHASE_LABELS.fetch(phase_key, phase_key.to_s.tr("_", " ").titleize),
        heartbeat_strategy: phase_key == "analyze_issue_provider_attempt" ? "provider_attempt_periodic" : "none",
        cancellation_strategy: phase_key == "analyze_issue_provider_attempt" ? "cooperative_activity_heartbeat" : "activity_timeout_only"
      )
      agent_run.record_issue_analysis_diagnostics!(
        base_metadata.merge(
          status: "running",
          started_at: started_at.iso8601,
          finished_at: nil,
          budget_seconds: budget_seconds
        )
      )

      track_phase(
        agent_run_id: agent_run.id,
        phase_key: phase_key,
        phase_group: "agent",
        agent_run: agent_run,
        metadata: metadata,
        started_at: started_at,
        budget_seconds: budget_seconds
      ) do
        yield
      end.tap do
        agent_run.record_issue_analysis_diagnostics!(
          base_metadata.merge(
            status: "completed",
            finished_at: Time.current.iso8601
          )
        )
      end
    rescue => e
      agent_run.record_issue_analysis_diagnostics!(
        base_metadata.merge(
          status: "failed",
          finished_at: Time.current.iso8601,
          error_class: e.class.name,
          error_message: e.message.to_s.truncate(200)
        )
      )
      raise
    end
  end
end
