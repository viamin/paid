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
    # Bodies of Paid's own structured issue comments (enhancement rounds,
    # clarifying-answers postings, stop-for-manual-review notices). Used to
    # EXCLUDE Paid's comments from the fresh-human-signal scan by content —
    # a credential-agnostic check, since PAT-backed projects post them as
    # the PAT user rather than the bot (#3849).
    PAID_MARKER_COMMENT_BODIES = [
      EnhanceIssueActivity::COMMENT_MARKER,
      ClarifyingQuestions::Load::ANSWER_MARKER,
      IssueEnhancements::StopForManualReview::COMMENT_MARKER
    ].freeze

    # Bridges a response-shaped failure (`AgentHarness::Response` with
    # `success? == false`) onto the existing rescue-clause path so the phase
    # recorder marks the attempt as `failed` instead of `completed`. CLI-backed
    # providers (Codex, OpenCode, claude outside text mode) normally report
    # nonzero exits as an unsuccessful Response, not as a raised error, so
    # without this promotion the `analyze_issue_provider_attempt` phase
    # would silently carry a misleading `completed` status — which then makes
    # a later timeout during the failover provider report the wrong
    # provider/status in the `agent_run_phases` history.
    class UnsuccessfulResponseError < StandardError
      attr_reader :response

      def initialize(response)
        @response = response
        error_message = response.respond_to?(:error) ? response.error.to_s : "unknown"
        super("Provider returned unsuccessful response: #{error_message}")
      end
    end

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
      all_comments = client.issue_comments(project.full_name, issue.github_number)
      comments = trusted_comments(project, all_comments)

      context = build_context(agent_run, project, issue)
      cycle_state = build_cycle_state(issue, all_comments, project)
      response = call_llm(agent_run, prompt_for(project, issue, comments, context, cycle_state))
      issue.clear_issue_analysis_backoff!
      parsed = parse_response!(agent_run, response)
      parsed = enforce_cap_override(issue, cycle_state, parsed)
      persist_verdict!(issue, parsed)

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
        knowledge_sections: context[:bundle_sections],
        enhance_issue_rounds: cycle_state[:enhance_issue_rounds]
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

    # @spec ISSUE-ANALYSIS-003 ISSUE-ANALYSIS-006 ISSUE-ANALYSIS-007 ISSUE-ANALYSIS-013
    def call_llm(agent_run, prompt)
      user_setting = owner_user_setting(agent_run.project)
      providers = chat_providers(agent_run.project)
      rate_limited_count = 0
      earliest_reset_at = nil
      attempted_failures = []

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
            llm_response = AgentHarness.send_message(prompt, **llm_options(provider))
            # Promote response-shaped failures to an exception so the phase
            # recorder marks this attempt as `failed` (ISSUE-ANALYSIS-012).
            # Without the raise the tracked block would return normally and
            # both `agent_run_phases` and `issue_analysis_diagnostics` would
            # carry a misleading `completed` status for the failed attempt —
            # a later timeout during the failover provider would then pin
            # the wrong provider/status in the run's history.
            if llm_response.respond_to?(:success?) && !llm_response.success?
              raise UnsuccessfulResponseError.new(llm_response)
            end
            llm_response
          end
        end
        record_runner_success(user_setting, provider)
        return response
      rescue UnsuccessfulResponseError => e
        log_failed_response(agent_run, provider, e.response)
        category = classify_response_error(e.response)
        record_provider_attempt_failure!(
          agent_run: agent_run, provider: provider, attempt: index + 1, category: category,
          exit_code: e.response.respond_to?(:exit_code) ? e.response.exit_code : nil,
          message: e.response.respond_to?(:error) ? e.response.error : nil
        )
        attempted_failures << { provider: provider.to_s, category: category }
        reset_at = record_response_failure(user_setting, provider, e.response)
        if reset_at
          rate_limited_count += 1
          earliest_reset_at = [ earliest_reset_at, reset_at ].compact.min
        end
      rescue AgentHarness::RateLimitError => e
        rate_limited_count += 1
        earliest_reset_at = [ earliest_reset_at, e.reset_time ].compact.min
        record_runner_rate_limit(user_setting, provider, reset_at: e.reset_time)
        log_provider_failure(agent_run, provider, e)
        record_provider_attempt_failure!(
          agent_run: agent_run, provider: provider, attempt: index + 1, category: :rate_limited,
          exit_code: nil, message: e.message
        )
        attempted_failures << { provider: provider.to_s, category: :rate_limited }
      rescue AgentHarness::AuthenticationError => e
        record_runner_auth_failure(user_setting, provider)
        log_provider_failure(agent_run, provider, e)
        record_provider_attempt_failure!(
          agent_run: agent_run, provider: provider, attempt: index + 1, category: :auth_expired,
          exit_code: nil, message: e.message
        )
        attempted_failures << { provider: provider.to_s, category: :auth_expired }
      rescue AgentHarness::Error => e
        record_runner_failure(user_setting, provider)
        log_provider_failure(agent_run, provider, e)
        category = failure_category_for(e)
        record_provider_attempt_failure!(
          agent_run: agent_run, provider: provider, attempt: index + 1, category: category,
          exit_code: nil, message: e.message
        )
        attempted_failures << { provider: provider.to_s, category: category }
      end

      raise_llm_failure!(agent_run, rate_limited_count, earliest_reset_at, attempted_failures)
    end

    # @spec ISSUE-ANALYSIS-006
    # When every attempted provider failed specifically because it is
    # rate-limited, this is a transient outage rather than a permanent
    # failure: park the run in "rate_limited" (mirrors the create_pr runner
    # path) so StaleRunDetectorJob re-queues it once the window clears,
    # instead of failing the issue analysis permanently. Any other failure
    # mix (including "no candidates at all") keeps the existing non-retryable
    # AnalyzeIssueLlmFailed error.
    def raise_llm_failure!(agent_run, rate_limited_count, reset_at, attempted_failures)
      attempted_providers = attempted_failures.map { |failure| failure[:provider] }

      if attempted_providers.any? && rate_limited_count == attempted_providers.size
        agent_run.rate_limit!(
          error: "All LLM providers rate limited: #{attempted_providers.join(', ')}",
          reset_at: reset_at || 60.seconds.from_now
        )
        raise Temporalio::Error::ApplicationError.new(
          "All LLM providers are currently rate limited",
          type: "RateLimit"
        )
      end

      raise Temporalio::Error::ApplicationError.new(
        issue_analysis_provider_exhaustion_message(attempted_failures),
        type: "AnalyzeIssueLlmFailed",
        non_retryable: true
      )
    end

    # @spec ISSUE-ANALYSIS-010 ISSUE-ANALYSIS-013
    # Summarizes attempted providers and their normalized failure categories
    # (never the raw provider error text, which may contain secrets) so the
    # durable terminal error is actionable without re-reading process logs.
    def issue_analysis_provider_exhaustion_message(attempted_failures)
      return "All issue-analysis providers exhausted" if attempted_failures.empty?

      summary = attempted_failures.map { |f| "#{f[:provider]} (#{f[:category]})" }.join(", ")
      "All issue-analysis providers exhausted: #{summary}"
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

    # @spec ISSUE-ANALYSIS-013
    # Prefers a raised error's own error_category (e.g. ProviderInstallationError
    # defaults to :installation) over generic message classification, since the
    # error class already encodes a more specific category than regex matching
    # on its message would.
    def failure_category_for(error)
      (error.respond_to?(:error_category) && error.error_category) || AgentHarness::ErrorTaxonomy.classify(error)
    end

    # @spec ISSUE-ANALYSIS-013
    # Persists the durable, structured counterpart to the process-log-only
    # `log_provider_failure`/`log_failed_response` lines: provider, normalized
    # failure category, exit code (when known), and a redacted/truncated
    # message — via the same sanitizer used for runner-attempt error text, so
    # secrets and unbounded provider payloads never land in agent_run_logs.
    def record_provider_attempt_failure!(agent_run:, provider:, attempt:, category:, exit_code:, message:)
      agent_run.agent_run_logs.create!(
        log_type: "system",
        content: AgentRun::ErrorMessageSanitizer.call(text: message) || "(no error message)",
        metadata: {
          type: AgentRunLog::PROVIDER_FAILURE_TYPE,
          provider: provider.to_s,
          attempt: attempt,
          failure_category: category.to_s,
          exit_code: exit_code
        }.compact
      )
    rescue => log_error
      logger.warn(
        message: "agent_execution.analyze_issue_provider_failure_log_failed",
        agent_run_id: agent_run.id,
        provider: provider,
        error: log_error.message
      )
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

    # @spec ISSUE-ANALYSIS-014
    def prompt_for(project, issue, comments, context, cycle_state)
      <<~PROMPT
        You are an issue readiness assessor. Evaluate whether the given GitHub issue
        has enough context for an autonomous implementation agent to start working.

        Calibration (important — read carefully):
        - Codebase-determinable ambiguity is NOT a blocker. The `create_pr` agent
          reads the repository and can self-answer questions that are resolvable
          from the code (existing models, platform targets, patterns, etc.). Only
          flag ambiguity that genuinely changes the *product/scope/intent* of the
          implementation — questions the human must answer, not questions the
          code can answer.
        - A failed `create_pr` attempt is cheap and informative. An endless
          clarify loop is expensive and stalls the lane. When the issue is
          actionable in code, prefer letting `create_pr` try.
        - When prior enhancement rounds produced implementation context and no
          fresh human signal has arrived since, lean toward `sufficient_context:
          true` — another clarify round has near-zero marginal value.
        - When the round cap has been reached, a new clarification round is
          blocked regardless. Default to `sufficient_context: true` so the
          issue can move to `create_pr` instead of being parked in
          `manual_review`.

        Consider:
        - Does the issue title and description provide enough detail to start implementation?
        - Does the knowledge base contain relevant context (architecture, patterns, dependencies)?
        - Have prior enhancement rounds already provided enough implementation context for an agent to act on?
        - Is the only remaining ambiguity product/scope/intent (gating), or is it codebase-resolvable (non-gating)?

        Respond with ONLY valid JSON:
        {
          "sufficient_context": true or false,
          "reasoning": "Brief explanation of your assessment",
          "missing_context_areas": ["area1", "area2"]
        }

        When sufficient_context is true, missing_context_areas should be an empty array.
        When sufficient_context is false, list the specific areas that need clarification
        (must be product/scope/intent — not codebase-determinable).

        ## Repository
        #{project.full_name}

        ## Issue
        Title: #{issue.title}
        Number: ##{issue.github_number}
        Author: #{issue.github_creator_login}

        #{issue.body.to_s.truncate(20_000)}

        #{cycle_state_section(cycle_state)}

        ## Conversation
        #{format_comments(comments)}

        ## Retrieval Results
        #{format_search_results(context[:search_results])}

        #{context[:bundle_content].presence || "## Codebase Context\nNo context bundle entries were available."}
      PROMPT
    end

    # @spec ISSUE-ANALYSIS-014
    def cycle_state_section(cycle_state)
      return "" unless cycle_state[:has_history]

      <<~SECTION
        ## Cycle state
        - Prior enhancement rounds completed for this issue: #{cycle_state[:enhance_issue_rounds]}
        - Project's max enhancement rounds: #{cycle_state[:max_enhance_issue_reevaluation_rounds]}
        - Prior analyzer verdict: #{cycle_state[:prior_sufficient_context]}
        - Prior missing_context_areas: #{cycle_state[:prior_missing_context_areas].to_json}

        #{cycle_state[:prior_enhancement_summary].presence || 'No prior enhancement comment found.'}

        If `Prior analyzer verdict` is "true" but the run still re-evaluated, treat any
        remaining flagged area as already addressed unless a fresh human signal contradicts it.
      SECTION
    end

    # @spec ISSUE-ANALYSIS-014 ISSUE-ANALYSIS-015
    def build_cycle_state(issue, all_comments, project)
      rounds = issue.enhance_issue_rounds.to_i
      max_rounds = project.max_enhance_issue_reevaluation_rounds
      prior_verdict = issue.last_analyzer_sufficient_context
      prior_areas = issue.last_analyzer_missing_context_areas
      latest_enhancement_comment = latest_bot_enhancement_comment(project, all_comments)
      summary = enhancement_summary_text(latest_enhancement_comment)

      {
        enhance_issue_rounds: rounds,
        max_enhance_issue_reevaluation_rounds: max_rounds,
        prior_sufficient_context: prior_verdict.nil? ? "unknown" : prior_verdict.to_s,
        prior_missing_context_areas: prior_areas || [],
        prior_enhancement_summary: summary,
        has_history: rounds.positive? || prior_verdict.present? || summary.present?,
        fresh_human_signal_since_last_analysis: fresh_human_signal_since?(all_comments, project, issue.last_analyzed_at)
      }
    end

    # @spec ISSUE-ANALYSIS-014
    # The marker text alone is not a trust signal — any GitHub user can type
    # `<!-- paid:enhance-issue -->`. Reuse ClarifyingQuestions::CommentAdmission
    # so only marker comments authored by the project's GitHub App bot (whose
    # login is unspoofable) reach the analyzer prompt; otherwise an untrusted
    # commenter can inject arbitrary instructions into the Cycle-state section
    # and steer the verdict (#3842).
    def latest_bot_enhancement_comment(project, comments)
      enhancement_comments = comments.select do |comment|
        ClarifyingQuestions::CommentAdmission.paid_marker_comment?(
          project, comment.user&.login, comment
        )
      end
      enhancement_comments.max_by { |comment| comment.created_at || Time.at(0) }
    end

    def enhancement_summary_text(comment)
      return nil unless comment

      body = comment.body.to_s.sub(EnhanceIssueActivity::COMMENT_MARKER, "").strip
      body.truncate(2_000)
    end

    # @spec ISSUE-ANALYSIS-015
    # Whether a trusted human commented after Paid's last analyzer pass — the
    # signal `enforce_cap_override` checks before forcing
    # sufficient_context: true at the round cap (#3849). Anchored on the
    # locally stored `last_analyzed_at` (written only by #persist_verdict!,
    # never derived from GitHub content) rather than on the enhancement
    # marker comment, because `latest_bot_enhancement_comment` admits only
    # GitHub App bot authors and is permanently nil for PAT-backed projects
    # — anchoring there made this check dead code for exactly the projects
    # whose enhancement comments post as the PAT user. Paid's own
    # structured marker comments are excluded by body: on PAT-backed
    # projects they post as the (allowlisted) PAT user, and without the
    # exclusion each one would read as fresh human signal, keep reopening
    # the enhancement budget, and turn the cap into an infinite enhance
    # loop. Marker matching is safe for this EXCLUSION purpose — a spoofed
    # marker can only drop the spoofing comment out of this scan (and
    # untrusted logins are already filtered), never admit content into the
    # prompt; admission stays gated by CommentAdmission (#3842). Scoped to
    # comments only (not `github_updated_at`, which also advances on Paid's
    # own label/comment activity and would be too noisy a proxy for "a
    # human edited the body"): a false positive here would silently
    # restore the deadlock the override exists to close.
    def fresh_human_signal_since?(comments, project, anchor_time)
      return false unless anchor_time

      comments.any? do |comment|
        next false unless comment.created_at && comment.created_at > anchor_time
        next false if paid_marker_comment_body?(comment)

        login = comment.user&.login
        project.trusted_github_user?(login) && !project.paid_bot_author?(login)
      end
    end

    # @spec ISSUE-ANALYSIS-015
    # Exclusion-only and therefore spoof-safe: a forged marker can only drop
    # the forging comment out of the fresh-signal scan, never admit content
    # into the prompt (admission stays gated by
    # ClarifyingQuestions::CommentAdmission, #3842).
    def paid_marker_comment_body?(comment)
      body = comment.body.to_s
      PAID_MARKER_COMMENT_BODIES.any? { |marker| body.include?(marker) }
    end

    # @spec ISSUE-ANALYSIS-015
    # The prompt's calibration guidance asks the model to default to
    # sufficient_context: true once the round cap is reached, but that's a
    # soft instruction. An LLM that returns false anyway at the cap gets its
    # enhance_issue follow-up rejected at queue time
    # (QueueAgentRunActivity#enhancement_round_limit_reached?), re-parking
    # the issue in manual_review — the state-flapping deadlock #3842 fixed
    # only for the instruction-following case. Enforce the cap
    # deterministically instead — but only once an enhancement round has
    # actually run: cap 0 disables automatic enhancement, and its
    # pre-#3849 behavior (a false verdict parks the issue in manual_review
    # for a human to gate) must survive `0 >= 0` on the very first
    # analysis. The override is skipped when a human has provided fresh
    # signal since the last analyzer pass that this run hasn't reacted to
    # yet. In that case the analyzer's real verdict stands — and because a
    # plain trusted comment matches none of the counter-reset paths (answer
    # flow, needs-input label removal, body edit), the counter can still
    # sit at cap here, so reopen_enhancement_budget! restores the invariant
    # "suppression ⇒ counter below cap" and lets the re-evaluation round
    # queue instead of flapping back into manual_review (#3849).
    def enforce_cap_override(issue, cycle_state, parsed)
      return parsed unless cycle_state[:enhance_issue_rounds].positive? &&
        cycle_state[:enhance_issue_rounds] >= cycle_state[:max_enhance_issue_reevaluation_rounds]
      return parsed if parsed[:sufficient_context]

      if cycle_state[:fresh_human_signal_since_last_analysis]
        reopen_enhancement_budget!(issue, cycle_state)
        return parsed
      end

      logger.info(
        message: "agent_execution.analyze_issue_cap_override",
        issue_id: issue.id,
        issue_number: issue.github_number,
        enhance_issue_rounds: cycle_state[:enhance_issue_rounds],
        max_enhance_issue_reevaluation_rounds: cycle_state[:max_enhance_issue_reevaluation_rounds],
        raw_sufficient_context: parsed[:sufficient_context],
        raw_missing_context_areas: parsed[:missing_context_areas]
      )

      parsed.merge(sufficient_context: true, missing_context_areas: [])
    end

    # @spec ISSUE-ANALYSIS-015
    def reopen_enhancement_budget!(issue, cycle_state)
      return unless issue.persisted? && cycle_state[:enhance_issue_rounds].positive?

      issue.update!(enhance_issue_rounds: 0)
      logger.info(
        message: "agent_execution.analyze_issue_enhancement_budget_reopened",
        issue_id: issue.id,
        issue_number: issue.github_number,
        enhance_issue_rounds_before: cycle_state[:enhance_issue_rounds]
      )
    end

    # @spec ISSUE-ANALYSIS-014
    def persist_verdict!(issue, parsed)
      attrs = {
        last_analyzer_sufficient_context: parsed[:sufficient_context],
        last_analyzer_reasoning: parsed[:reasoning].to_s.truncate(2_000),
        last_analyzer_missing_context_areas: parsed[:missing_context_areas].to_a,
        last_analyzed_at: Time.current
      }
      issue.update_columns(attrs) if issue.persisted?
    rescue => e
      logger.warn(
        message: "agent_execution.analyze_issue_persist_verdict_failed",
        issue_id: issue.id,
        error_class: e.class.name,
        error: e.message
      )
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
    # Admit trusted human collaborators plus Paid's own structured marker
    # comments authored by the project's GitHub App bot. Without re-admitting
    # the bot's enhancement comments, the readiness assessor never sees the
    # implementation context the enhance agent already posted and re-flags
    # the issue as insufficient on every cycle. See
    # ClarifyingQuestions::CommentAdmission and Project#paid_bot_author?.
    def trusted_comments(project, comments)
      comments.select { |comment| ClarifyingQuestions::CommentAdmission.admissible?(project:, comment:) }
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
        cancellation_strategy: phase_key == "analyze_issue_provider_attempt" ? "cooperative_activity_heartbeat" : "activity_timeout_only",
        budget_seconds: budget_seconds
      )
      agent_run.record_issue_analysis_diagnostics!(
        base_metadata.merge(
          status: "running",
          started_at: started_at.iso8601,
          finished_at: nil
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
