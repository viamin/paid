# frozen_string_literal: true

require "shellwords"

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    # Returns true if the given provider key can be executed inside the
    # container. Replaces the former AGENT_COMMANDS.key? check. Container
    # executability is gated by ProviderSupport::CONTAINER_EXECUTABLE_PROVIDER_KEYS
    # — providers not in that set are filtered out upstream (UserSetting,
    # ProvidersController) before reaching provider_order.
    def self.container_executable?(provider_key)
      key = AGENT_TYPE_TO_PROVIDER.fetch(provider_key, provider_key)
      ProviderSupport.container_executable_provider_key?(key)
    end

    # Maps agent_type values to their canonical settings provider name.
    # Some agent types (e.g., "claude_code") share the same underlying provider as
    # a settings-level name ("claude"), so they should be deduplicated during fallback.
    AGENT_TYPE_TO_PROVIDER = {
      "claude_code" => "claude"
    }.freeze

    # No-op executor for provider instances used only for response parsing.
    NULL_EXECUTOR = Object.new.tap do |obj|
      obj.define_singleton_method(:execute) { |*, **| raise "NULL_EXECUTOR: not meant for execution" }
    end.freeze

    # Patterns that indicate a rate limit or quota error from provider output.
    RATE_LIMIT_PATTERNS = [
      /rate.?limit/i,
      /too many requests/i,
      /(?:\bHTTP[\/\s]*429\b|status[:\s]*429\b)/i,
      /quota exceeded/i,
      /free tier limit reached/i,
      /(?:you'?ve|you have)\s+hit\s+your\s+limit/i,
      /exhausted\s+your\s+capacity/i,
      /exhausted.*capacity/i, # intentionally loose — only used for exit-code failures, not timeout reclassification

      /(?:server|system)\s+(?:at\s+)?capacity/i,
      /(?:server|api|service)\s+overloaded/i,
      /out of (?:extra )?usage/i,
      /usage limit/i
    ].freeze

    # Timeout reclassification is intentionally stricter than generic
    # execution-failure classification because streamed stdout/stderr can
    # contain ordinary agent prose that mentions rate limiting.
    # "too many requests" is only matched when accompanied by HTTP 429 or
    # status code context to avoid false positives from conversational text.
    #
    # Note: bare "usage limit" (without exceeded/reached/hit) is deliberately
    # excluded here — it matches RATE_LIMIT_PATTERNS for exit-code failures
    # but is too loose for timeout reclassification where the output may
    # contain conversational text.
    TIMEOUT_RATE_LIMIT_PATTERNS = [
      /\bHTTP\s?429\b/i,
      /\b429\b.*\btoo many requests\b/i,
      /\btoo many requests\b.*\b429\b/i,
      /\bstatus[:\s]*429\b/i,
      /quota exceeded/i,
      /free tier limit reached/i,
      /(?:rate.?limit|usage limit) +(?:exceeded|reached|hit)/i,
      /(?:you'?ve|you have) +hit +your +limit/i,
      /exhausted(?: +your)? +capacity/i,
      /out of (?:extra )?usage/i
    ].freeze

    # Maximum number of log rows to inspect when reclassifying a timeout.
    # Caps memory and DB load on long-running, verbose agent attempts.
    TIMEOUT_RATE_LIMIT_LOG_LIMIT = 200

    # Default timeouts used when per-user settings are unavailable.
    # Runtime code resolves per-user values via UserSetting.
    DEFAULT_ISSUE_GOAL_TIMEOUT = 600        # 10 minutes wall clock
    DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT = 120   # 2 minutes without output = stuck
    DEFAULT_REVIEW_GOAL_IDLE_TIMEOUT = 300  # 5 minutes without output = stuck
    DEFAULT_CREATE_PR_IDLE_TIMEOUT = 300   # 5 minutes without output = stuck
    CHANGE_DETECTION_MAX_ATTEMPTS = 3
    CHANGE_DETECTION_RETRY_BACKOFF = 0.25
    POST_RUN_BOOKKEEPING_ERROR_TYPE = "PostRunBookkeepingFailed"

    def self.provider_order(agent_type:, fallback_enabled:, fallback_providers:)
      return [ agent_type ].select { |p| container_executable?(p) } unless fallback_enabled

      canonical = AGENT_TYPE_TO_PROVIDER.fetch(agent_type, agent_type)
      providers = [ agent_type ]
      seen = Set.new([ canonical ])

      Array(fallback_providers).each do |fallback|
        fallback_canonical = AGENT_TYPE_TO_PROVIDER.fetch(fallback, fallback)
        next if seen.include?(fallback_canonical)

        seen << fallback_canonical
        providers << fallback
      end

      providers.select { |p| container_executable?(p) }
    end

    def self.provider_attempt_count(agent_type:, fallback_enabled:, fallback_providers:)
      provider_order(
        agent_type: agent_type,
        fallback_enabled: fallback_enabled,
        fallback_providers: fallback_providers
      ).size
    end

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)
      track_phase(agent_run_id: agent_run_id, phase_key: "run_agent", phase_group: "agent", agent_run: agent_run) do
        prompt = agent_run.effective_prompt
        unless prompt
          raise Temporalio::Error::ApplicationError.new(
            "No prompt available for agent run", type: "MissingPrompt", non_retryable: true
          )
        end

        user_settings = resolve_user_settings(agent_run)
        providers = build_provider_order(agent_run, user_settings)
        provider_states = load_provider_state_cache(user_settings.user, providers)

        pre_agent_sha = nil
        last_error = nil
        last_attempted_label = nil
        timeout_error = nil
        rate_limit_reset_at = nil
        skipped_rate_limited_count = 0

        max_execution_seconds = agent_run.project.max_execution_seconds

        index = 0
        while index < providers.length
          provider_candidate = providers[index]
          # Check if the project's execution time limit has been exceeded
          if max_execution_seconds && agent_run.started_at && (Time.current - agent_run.started_at).to_i >= max_execution_seconds
            violation_result = Guardrails::ViolationHandler.call(
              agent_run: agent_run,
              violation_type: "time_limit",
              details: "Execution time limit of #{max_execution_seconds}s exceeded",
              metrics: { max_execution_seconds: max_execution_seconds, elapsed_seconds: (Time.current - agent_run.started_at).to_i }
            )
            return paused_result(agent_run_id) if violation_result.paused? || agent_run.paused?

            timeout_error = "Execution time limit of #{max_execution_seconds}s exceeded"
            break
          end

          # Skip routing keys whose provider entry has been deleted — attempting
          # execution would fail with "Unsupported provider" and leak internal
          # identifiers in user-visible error messages.
          if Provider.routing_key?(provider_candidate) && provider_entry_for(provider_candidate, user_settings.user).nil?
            agent_run.record_provider_attempt("Deleted provider entry", success: false, error_type: "unavailable")
            index += 1
            next
          end

          provider = provider_command_key(provider_candidate, agent_run, user_settings.user)
          attempt_label = provider_attempt_label(provider_candidate, agent_run, user_settings.user)
          provider_state_name = state_key_for(provider_candidate, provider, user_settings.user)
          heartbeat("provider_attempt", provider, index)

          # Skip unavailable providers, tracking rate-limited skips separately
          if provider_unavailable?(user_settings, provider_state_name, provider_states)
            state = provider_states[provider_state_name]
            error_type = state&.rate_limited? ? "rate_limited" : "unavailable"
            skipped_rate_limited_count += 1 if error_type == "rate_limited"
            error_message = if error_type == "rate_limited" && state&.rate_limited_until.present?
              "Skipped due to cached rate limit until #{state.rate_limited_until.iso8601}"
            elsif error_type == "unavailable" && state&.circuit_open?
              "Skipped because provider circuit is open"
            end
            agent_run.record_provider_attempt(
              attempt_label,
              success: false,
              error_type: error_type,
              error_message: error_message
            )
            index += 1
            next
          end

          # Log provider switch when we have a previous actually-attempted provider.
          # Use attempt_label (per-entry identifier) so entries sharing the same
          # command key (e.g. two OpenCode API-key entries) are distinguishable.
          if last_attempted_label
            agent_run.log_provider_switch!(last_attempted_label, attempt_label, last_error || "fallback")
          end

          begin
            last_attempted_label = attempt_label
            attempt_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            provider_result = run_agent_with_provider(agent_run, provider_candidate, prompt, user_settings)
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            pre_agent_sha = provider_result.fetch(:pre_agent_sha)

            # Success - heartbeat and record final provider
            heartbeat("provider_completed", provider)
            record_provider_success(user_settings, provider_state_name, provider_states)
            agent_run.record_provider_attempt(attempt_label, success: true, duration_seconds: attempt_duration)
            # Persist the routing key so multiple entries sharing the same
            # provider_key (e.g. several OpenCode API-key entries with
            # different models) remain distinguishable in UI and retry logic.
            agent_run.update!(final_provider: attempt_label)

            # Skip git post-processing for goals that don't clone a repo.
            # These runs only interact via the GitHub API proxy — no git repo exists.

            # Evaluate pre-commit requirements against the working directory
            # before committing, so blocking failures prevent commits.
            if agent_run.repo_cloned?
              pre_commit_result = evaluate_pre_commit_requirements(agent_run)
              if pre_commit_result[:blocking]
                agent_run.log!("system", "Blocked by failing pre-commit requirements",
                  metadata: { pre_commit_results: pre_commit_result[:results] })
                return {
                  agent_run_id: agent_run_id,
                  success: false,
                  has_changes: check_for_changes(agent_run, pre_agent_sha),
                  output_present: provider_result.fetch(:output_present),
                  final_provider: attempt_label,
                  error: "pre_commit_requirements_failed"
                }
              end

              commit_uncommitted_changes(agent_run)
            end

            has_changes = agent_run.repo_cloned? ? check_for_changes(agent_run, pre_agent_sha) : false

            if !has_changes && !provider_result.fetch(:output_present)
              agent_run.log!("system", "Provider completed with no output and no changes")
            end

            return {
              agent_run_id: agent_run_id,
              success: true,
              has_changes: has_changes,
              output_present: provider_result.fetch(:output_present),
              review_threads_already_addressed: provider_result.fetch(:review_threads_already_addressed, false),
              final_provider: attempt_label
            }
          rescue ProviderRateLimitError => e
            last_error = "rate_limited"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            rate_limit_reset_at = [ rate_limit_reset_at, e.reset_at ].compact.min
            persist_rate_limit(user_settings, provider_state_name, provider_states, e.reset_at)
            agent_run.record_provider_attempt(
              attempt_label,
              success: false,
              error_type: "rate_limited",
              error_message: e.message,
              duration_seconds: attempt_duration
            )
            logger.info(message: "agent_execution.rate_limited", provider: provider, agent_run_id: agent_run.id, duration_seconds: attempt_duration)
            insert_rate_limit_fallbacks!(
              providers: providers,
              index: index,
              provider_candidate: provider_candidate,
              provider: provider,
              agent_run: agent_run
            )
          rescue InfiniteLoopError => e
            last_error = "infinite_loop"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            if cancelled_by_cleanup?(agent_run)
              record_cleanup_cancelled_attempt(agent_run, attempt_label, provider, e)
              break
            end
            record_provider_failure(user_settings, provider_state_name, provider_states)
            agent_run.record_provider_attempt(
              attempt_label,
              success: false,
              error_type: "infinite_loop",
              error_message: e.message,
              duration_seconds: attempt_duration
            )
            logger.warn(message: "agent_execution.infinite_loop_detected", agent_run_id: agent_run.id, reason: e.message, duration_seconds: attempt_duration)

            result = Guardrails::ViolationHandler.call(
              agent_run: agent_run,
              violation_type: "loop_detected",
              details: e.message,
              metrics: { detection_reason: e.message }
            )
            return paused_result(agent_run_id) if result.paused? || agent_run.paused?

            agent_run.fail!(error: "Infinite loop detected: #{e.message}") unless agent_run.finished?

            raise Temporalio::Error::ApplicationError.new(
              "Infinite loop detected: #{e.message}",
              type: "InfiniteLoopDetected",
              non_retryable: true
            )
          rescue ProviderTimeoutError => e
            last_error = "timeout"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            timeout_error ||= e.message
            if cancelled_by_cleanup?(agent_run)
              record_cleanup_cancelled_attempt(agent_run, attempt_label, provider, e)
              break
            end
            record_provider_failure(user_settings, provider_state_name, provider_states)
            agent_run.record_provider_attempt(
              attempt_label,
              success: false,
              error_type: "timeout",
              error_message: e.message,
              duration_seconds: attempt_duration
            )
            logger.warn(message: "agent_execution.provider_timeout", provider: provider, agent_run_id: agent_run.id, error: e.message, duration_seconds: attempt_duration)
            break
          rescue ProviderAuthExpiredError => e
            last_error = "auth_expired"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            auth_provider = ProviderSupport.harness_provider_key_for(e.provider)
            agent_run.auth_expire!(error: e.message, provider: auth_provider)
            agent_run.record_provider_attempt(
              attempt_label,
              success: false,
              error_type: "auth_expired",
              error_message: e.message,
              duration_seconds: attempt_duration
            )
            logger.warn(message: "agent_execution.auth_expired", provider: provider, agent_run_id: agent_run.id, error: e.message, duration_seconds: attempt_duration)
            break
          rescue ProviderExecutionError => e
            last_error = "error"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            if cancelled_by_cleanup?(agent_run)
              record_cleanup_cancelled_attempt(agent_run, attempt_label, provider, e)
              break
            end
            record_provider_failure(user_settings, provider_state_name, provider_states)
            agent_run.record_provider_attempt(
              attempt_label,
              success: false,
              error_type: "error",
              error_message: e.message,
              duration_seconds: attempt_duration
            )
            logger.warn(message: "agent_execution.provider_failed", provider: provider, agent_run_id: agent_run.id, error: e.message, duration_seconds: attempt_duration)

            if container_dead_after_exec_error?(agent_run, e)
              logger.error(
                message: "agent_execution.container_dead_breaking_provider_loop",
                agent_run_id: agent_run.id,
                container_id: agent_run.container_id,
                error: e.message
              )
              break
            end
          end

          index += 1
        end

        # When all providers were skipped due to cached rate-limit state (no
        # attempts made), compute the earliest reset time from provider states.
        all_skipped_rate_limited = providers.any? && skipped_rate_limited_count == providers.size
        if rate_limit_reset_at.nil? && all_skipped_rate_limited
          reset_candidates = providers.filter_map do |provider|
            state = provider_states[state_key_for(provider, provider_command_key(provider, agent_run, user_settings.user), user_settings.user)]
            state&.rate_limited_until
          end
          rate_limit_reset_at = reset_candidates.min if reset_candidates.any?
        end

        # If a guardrail (e.g., cost budget enforcement from TokenUsageTracker)
        # paused the run during execution, preserve the paused state instead of
        # overwriting it with a terminal status.
        agent_run.reload
        return paused_result(agent_run_id) if agent_run.paused?

        # All providers exhausted. Timeout takes precedence over rate_limited
        # because it indicates an actual execution attempt that should trigger
        # ProcessRunQueueJob to re-schedule work.
        if timeout_error.present?
          timed_out = !agent_run.finished? && agent_run.timeout!(error: timeout_error)
          Notifications::Rules::ZeroIterationTimeout.call(scope: agent_run) if timed_out
          # Skip queue processing when cleanup killed the run — the timeout
          # was not a real provider issue, so there is nothing to re-schedule.
          # (agent_run was reloaded above, so the model method sees current state)
          ProcessRunQueueJob.perform_later if timed_out && !agent_run.cancelled_by_cleanup?
        elsif !agent_run.finished? && (last_error == "rate_limited" || all_skipped_rate_limited)
          provider_list = providers.any? ? provider_attempt_labels(providers, agent_run, user_settings.user).join(", ") : "none"
          agent_run.rate_limit!(
            error: "All providers rate limited: #{provider_list}",
            reset_at: rate_limit_reset_at
          )
        elsif !agent_run.finished?
          provider_list = providers.any? ? provider_attempt_labels(providers, agent_run, user_settings.user).join(", ") : "none"
          agent_run.fail!(error: "All providers exhausted: #{provider_list}")
        end
        raise Temporalio::Error::ApplicationError.new(
          "All providers exhausted",
          type: "AllProvidersExhausted",
          non_retryable: true
        )
      end
    end

    # Custom error classes for provider-specific failures
    class ProviderRateLimitError < StandardError
      attr_reader :reset_at

      def initialize(message, reset_at: nil)
        super(message)
        @reset_at = reset_at
      end
    end

    class ProviderAuthExpiredError < StandardError
      attr_reader :provider

      def initialize(message, provider:)
        super(message)
        @provider = provider
      end
    end

    class ProviderExecutionError < StandardError; end
    class ProviderTimeoutError < StandardError; end
    class InfiniteLoopError < StandardError; end
    CommandContext = Struct.new(:provider_candidate, :provider, :user, keyword_init: true)

    private

    def paused_result(agent_run_id)
      {
        agent_run_id: agent_run_id,
        success: false,
        paused: true,
        has_changes: false,
        output_present: false
      }
    end

    # Resolves user settings for the agent run by finding the appropriate user.
    # Tries the project creator first, then falls back to the account's owner member.
    def resolve_user_settings(agent_run)
      AgentRuns::UserSettingsResolver.call(project: agent_run.project, strict: true)
    rescue AgentRuns::UserSettingsResolver::MissingUserError
      raise Temporalio::Error::ApplicationError.new(
        "No user available for agent run settings",
        type: "MissingUser",
        non_retryable: true
      )
    end

    # Builds the ordered list of providers to attempt.
    # Uses fallback providers if enabled, otherwise just the agent's type.
    # Rate-limit fallback providers are tracked separately (via
    # @rate_limit_fallbacks) and handled during execution; they do not
    # modify the provider order returned by this method.
    #
    # @return [Array<String>] Provider names in priority order
    def build_provider_order(agent_run, user_settings)
      if agent_run.provider
        providers = [ agent_run.provider.routing_key ]
        if user_settings.fallback_enabled
          providers.concat(user_settings.fallback_priority_for(primary_provider: agent_run.provider.routing_key, identifiers: true))
        end
      else
        providers =
          if user_settings.fallback_enabled
            fallback_providers = user_settings.fallback_priority_for(
              primary_provider: canonical_provider(agent_run.agent_type),
              identifiers: true
            )
            deduplicate_provider_candidates(
              primary_provider: agent_run.agent_type,
              fallback_providers: fallback_providers,
              user: user_settings.user
            )
          else
            [ agent_run.agent_type ].select { |provider| self.class.container_executable?(provider) }
          end
      end

      providers = providers.select do |provider_candidate|
        self.class.container_executable?(provider_command_key(provider_candidate, agent_run, user_settings.user))
      end
      if providers.empty? && fallback_to_default_provider?(agent_run)
        providers = default_provider_candidates(agent_run, user_settings)
      end

      @rate_limit_fallbacks = load_rate_limit_fallbacks(user_settings.user)
      @inserted_rate_limit_fallbacks = Set.new

      providers
    end

    # Checks if a provider is currently unavailable (rate limited or circuit open).
    #
    # @return [Boolean] true if provider should be skipped
    def provider_unavailable?(user_settings, provider_state_name, provider_states)
      state = provider_states.fetch(provider_state_name) do
        provider_states[provider_state_name] = user_settings.user.provider_states.find_by(provider_name: provider_state_name)
      end
      return false unless state

      # Check for circuit recovery before deciding
      state.check_circuit_recovery!(timeout: user_settings.circuit_breaker_timeout_seconds)

      state.unavailable?
    end

    # Records a rate limit for a provider.
    def persist_rate_limit(user_settings, provider_state_name, provider_states, reset_at = nil)
      state = provider_state_for(user_settings, provider_state_name, provider_states)
      state.mark_rate_limited!(reset_at: reset_at)
    end

    # Records a successful provider execution.
    def record_provider_success(user_settings, provider_state_name, provider_states = nil)
      state = provider_states ? provider_states[provider_state_name] : user_settings.user.provider_states.find_by(provider_name: provider_state_name)
      state&.record_success!
    end

    # Records a failed provider execution.
    def record_provider_failure(user_settings, provider_state_name, provider_states)
      state = provider_state_for(user_settings, provider_state_name, provider_states)
      state.record_failure!(threshold: user_settings.circuit_breaker_failure_threshold)
    end

    # True when the agent run we're executing has already been force-timed-out
    # by external cleanup (e.g. `dev:cleanup` or `StaleRunDetectorJob` killed
    # our container). In that case the failure we just rescued was caused by
    # cleanup, not by the provider, so we must not penalize the circuit breaker.
    def cancelled_by_cleanup?(agent_run)
      agent_run.reload
      agent_run.cancelled_by_cleanup?
    rescue ActiveRecord::RecordNotFound
      false
    end

    # Mirror of the failed-attempt bookkeeping for externally-cancelled runs:
    # records the attempt with a distinct error_type so the UI can show what
    # happened, but skips both record_provider_failure and the standard warn
    # log (which would imply a real provider problem).
    def record_cleanup_cancelled_attempt(agent_run, attempt_label, provider, error)
      agent_run.record_provider_attempt(attempt_label, success: false, error_type: "cancelled_by_cleanup")
      logger.info(
        message: "agent_execution.cancelled_by_cleanup",
        provider: provider,
        agent_run_id: agent_run.id,
        error: error.message
      )
    end

    # Returns the canonical settings-level provider name for a given agent type.
    def canonical_provider(provider)
      AGENT_TYPE_TO_PROVIDER.fetch(provider, provider)
    end

    def default_provider_candidates(agent_run, user_settings)
      first_key = ProviderSupport.container_executable_provider_keys.first
      default_fallback = first_key ? ProviderSupport.agent_type_for(first_key) : "claude_code"

      candidates = [
        user_settings.default_provider_identifier_for_goal(agent_run.goal),
        default_fallback
      ].compact_blank

      seen = Set.new
      candidates.each_with_object([]) do |provider_candidate, runnable|
        provider = provider_command_key(provider_candidate, agent_run, user_settings.user)
        next unless self.class.container_executable?(provider)

        canonical = canonical_provider(provider)
        next if seen.include?(canonical)

        seen << canonical
        runnable << provider_candidate
      end
    end

    def fallback_to_default_provider?(agent_run)
      return true if agent_run.provider.present?

      provider_key = Provider.provider_key_for_agent_type(agent_run.agent_type)
      AgentRun::AGENT_TYPES.include?(agent_run.agent_type) &&
        ProviderSupport.supported_provider_key?(provider_key)
    end

    def provider_state_for(user_settings, provider_state_name, provider_states)
      provider_states[provider_state_name] ||= user_settings.provider_state_for(provider_state_name)
    end

    def load_provider_state_cache(user, providers)
      provider_state_names = providers.map { |provider| state_key_for(provider, provider_command_key(provider, nil, user), user) }.uniq
      user.provider_states.where(provider_name: provider_state_names).index_by(&:provider_name)
    end

    # Runs the agent with a specific provider.
    # Raises ProviderRateLimitError, ProviderTimeoutError, or ProviderExecutionError on failure.
    #
    # @return [Hash] The pre-agent SHA and whether output was present
    def run_agent_with_provider(agent_run, provider_candidate, prompt, user_settings)
      container_service = reconnect_container(agent_run)

      unless container_service.container_running?
        container_exit_info = container_exit_diagnostics(container_service)
        raise ProviderExecutionError,
          "Container #{agent_run.container_id} is not running. #{container_exit_info}"
      end

      provider = provider_command_key(provider_candidate, agent_run, user_settings.user)

      unless self.class.container_executable?(provider)
        raise ProviderExecutionError, "Unsupported provider: #{provider}"
      end

      # Refresh the co-author trailer file before the agent runs so any
      # intermediate commits it creates via the commit-msg hook carry the
      # trailer for the provider actually producing them. Without this,
      # rate-limit fallback would leave the hook bound to the initial
      # provider's trailer for every subsequent commit in the run.
      if agent_run.repo_cloned?
        refresh_co_author_trailer(container_service, agent_run, provider_candidate, user_settings.user)
      end

      prompt = augment_prompt_for_goal(agent_run, prompt)
      command_context = CommandContext.new(
        provider_candidate: provider_candidate,
        provider: provider,
        user: user_settings.user
      )
      command = build_command(command_context, prompt)
      command_env = command_env_for(command_context, prompt)
      command_preparation = command_preparation_for(command_context, prompt)

      heartbeat = Containers::HeartbeatSetup.new(
        provider: provider,
        worktree_path: agent_run.worktree_path,
        host_heartbeat_path: container_service.heartbeat_host_path
      )
      if heartbeat.available?
        command_env = command_env.merge(heartbeat.env)
        command_preparation = merge_preparations(command_preparation, heartbeat.preparation)
      end

      pre_agent_sha = capture_head_sha(container_service, agent_run)

      raise ProviderExecutionError, "Agent run already finished with status #{agent_run.status}" if agent_run.finished?

      # Only start! on first provider attempt.
      agent_run.start! unless agent_run.running?

      agent_run.log!("system", "Starting #{provider} agent in container")
      agent_run.log!("system", "Prompt: #{prompt.truncate(500)}")
      log_container_context(agent_run, provider)
      execution_started_at = Time.current

      effective_timeout = if agent_run.create_issue_goal? || agent_run.enhance_issue_goal? || agent_run.analyze_issue_goal?
        user_settings&.issue_goal_timeout_seconds || DEFAULT_ISSUE_GOAL_TIMEOUT
      else
        user_settings&.agent_timeout_seconds || agent_timeout
      end

      # Cap timeout by the project's max execution time limit.
      # Uses started_at to compute remaining budget so the limit covers
      # the full run, not just a single provider attempt.
      max_exec = agent_run.project.max_execution_seconds
      if max_exec && agent_run.started_at
        remaining = (max_exec - (Time.current - agent_run.started_at).to_i).clamp(1, max_exec)
        effective_timeout = [ effective_timeout, remaining ].min
      end

      effective_idle_timeout = if agent_run.create_issue_goal? || agent_run.enhance_issue_goal? || agent_run.analyze_issue_goal?
        user_settings&.issue_goal_idle_timeout_seconds || DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT
      elsif agent_run.review_goal?
        user_settings&.review_goal_idle_timeout_seconds || DEFAULT_REVIEW_GOAL_IDLE_TIMEOUT
      elsif agent_run.create_pr_goal?
        user_settings&.create_pr_idle_timeout_seconds || DEFAULT_CREATE_PR_IDLE_TIMEOUT
      end

      # Periodic heartbeats during container execution complement the
      # checkpoint heartbeats at provider attempt boundaries (lines 106, 129).
      # Provider calls can run for many minutes, so without periodic
      # heartbeats the 120s heartbeat_timeout would fire mid-execution.
      result = with_periodic_heartbeat("executing", provider, agent_run: agent_run) do
        container_service.execute(
          command,
          timeout: effective_timeout,
          idle_timeout: heartbeat.idle_timeout_for(effective_idle_timeout),
          env: command_env,
          preparation: command_preparation,
          heartbeat_path: heartbeat.available? ? heartbeat.heartbeat_path : nil,
          abort_patterns: aggregated_abort_patterns
        )
      end
      stdout = normalize_output_text(result[:stdout])
      stderr = normalize_output_text(result[:stderr])

      if result.success?
        # Detect provider credit/quota errors that slip through as successful
        # exits. Some providers (e.g. OpenRouter) return a billing error as
        # the only stdout line with exit code 0. The agent never actually ran,
        # so treat this as a provider failure to trigger fallback/retry.
        combined_output = [ stdout, stderr ].compact.join("\n")
        sanitized_output = strip_prompt_echo(combined_output, prompt)
        if insufficient_credits_error?(sanitized_output)
          raise ProviderExecutionError,
            "Provider credit/quota error from #{provider}: #{sanitized_output.truncate(500)}"
        end

        output_present = stdout.present? || stderr.present?
        track_harness_tokens(agent_run, provider_candidate, provider, user_settings.user, result, execution_started_at)
        agent_run.log!("system", "Agent execution succeeded with #{provider}")
        return {
          pre_agent_sha: pre_agent_sha,
          output_present: output_present,
          review_threads_already_addressed: review_threads_already_addressed?(stdout: stdout, stderr: stderr, prompt: prompt)
        }
      end

      output = (stderr.presence || stdout).to_s.strip
      rate_limit_output = strip_prompt_echo(output, prompt)

      if auth_expired_error?(provider, rate_limit_output)
        raise ProviderAuthExpiredError.new(output.truncate(500), provider: provider)
      end

      # Check if this is a rate limit error
      if rate_limit_error?(rate_limit_output)
        reset_at = rate_limit_reset_at(provider, rate_limit_output)
        raise ProviderRateLimitError.new("Rate limited by #{provider}", reset_at: reset_at)
      end

      # Other execution error
      raise ProviderExecutionError, "Agent exited with code #{result[:exit_code]}: #{output.truncate(500)}"
    rescue Containers::Provision::TimeoutError => e
      # execution_started_at is nil if the timeout fires before execution
      # begins (e.g. during start!/callbacks); recent_timeout_output
      # short-circuits on blank.
      timeout_output = recent_timeout_output(agent_run, since: execution_started_at, prompt: prompt)
      if timeout_rate_limit_error?(timeout_output)
        reset_at = rate_limit_reset_at(provider, timeout_output)
        raise ProviderRateLimitError.new("Rate limited by #{provider}", reset_at: reset_at)
      end

      timeout_type = case e
      when Containers::Provision::StartupTimeoutError then "startup"
      when Containers::Provision::IdleTimeoutError then "idle"
      else "wall_clock"
      end
      raise ProviderTimeoutError, "#{timeout_type}_timeout: #{e.message}"
    rescue Containers::Provision::OutputAbortError => e
      # The container was stopped early because stderr matched a fatal
      # provider quota pattern (e.g. KiloCode "Free tier limit reached").
      # Classify as rate-limited so dashboards and retry logic see the
      # real root cause instead of a generic timeout.
      reset_at = rate_limit_reset_at(provider, e.matched_output.to_s)
      raise ProviderRateLimitError.new(
        "Rate limited by #{provider}: #{e.matched_output.to_s.truncate(200)}",
        reset_at: reset_at
      )
    rescue Containers::Provision::ExecutionError => e
      raise ProviderExecutionError, "Docker exec error: #{e.message}"
    end

    # Checks if the agent run is stuck in an infinite loop by analyzing
    # recent output logs. Raises InfiniteLoopError if a loop is detected.
    def check_infinite_loop!(agent_run)
      result = AgentRuns::DetectInfiniteLoop.call(agent_run: agent_run)
      raise InfiniteLoopError, result.reason if result.loop_detected?
    end

    # Records container and worktree context at agent-run start for
    # traceability.  If a future run exhibits cross-run contamination
    # (see #905), these log entries make it possible to determine whether
    # the container/worktree was reused.
    def log_container_context(agent_run, provider)
      logger.info(
        message: "agent_execution.container_context",
        agent_run_id: agent_run.id,
        provider: provider.to_s,
        container_id: agent_run.container_id,
        worktree_path: agent_run.worktree_path
      )
    end

    # Checks if the output indicates a rate limit error.
    def rate_limit_error?(output)
      return false if output.blank?

      RATE_LIMIT_PATTERNS.any? { |pattern| output.match?(pattern) }
    end

    def timeout_rate_limit_error?(output)
      return false if output.blank?

      TIMEOUT_RATE_LIMIT_PATTERNS.any? { |pattern| output.match?(pattern) }
    end

    def auth_expired_error?(provider, output)
      return false if output.blank?

      provider_key = ProviderSupport.provider_key_for_agent_type(provider)
      ProviderSupport.error_classification_patterns_for(provider_key, :auth_expired)
        .any? { |pattern| output.match?(pattern) }
    end

    QUOTA_ERROR_MAX_OUTPUT_LENGTH = 500

    # Detects provider-level credit/quota exhaustion errors surfaced as
    # agent output. Used in the successful-exit-code path to catch cases
    # where a provider (e.g. OpenRouter) returns a billing error as the
    # only stdout content with exit code 0.
    #
    # Real billing/quota errors are short standalone messages. If the
    # sanitized output exceeds QUOTA_ERROR_MAX_OUTPUT_LENGTH, the agent
    # clearly produced substantial work and should not be misclassified
    # as a quota error even if a pattern substring appears in structured
    # output (e.g. JSONL streaming events containing rspec test names).
    def insufficient_credits_error?(output)
      return false if output.blank?
      return false if output.length > QUOTA_ERROR_MAX_OUTPUT_LENGTH

      ProviderSupport.aggregated_error_classification_patterns(:quota)
        .any? { |pattern| output.match?(pattern) }
    end

    def strip_prompt_echo(output, prompt)
      output = normalize_output_text(output)
      prompt = normalize_output_text(prompt)

      return output if output.blank? || prompt.blank?

      sanitized_output = output.gsub(prompt, "")
      prompt_lines = prompt.each_line.map { |line| normalize_output_line(line, strip_prompt_prefixes: true) }.reject(&:blank?).to_set

      sanitized_output.each_line.filter_map do |line|
        normalized_line = normalize_output_line(line, strip_prompt_prefixes: true)
        next if normalized_line.blank? || prompt_lines.include?(normalized_line)

        line.rstrip
      end.join("\n").strip
    end

    def normalize_output_line(line, strip_prompt_prefixes: false)
      normalized_line = line.to_s.strip
      if strip_prompt_prefixes
        normalized_line = normalized_line.sub(/\A(?:user|assistant|system)\s*[:|-]?\s*/i, "")
        normalized_line = normalized_line.sub(/\A(?:>\s*)+/, "")
      end

      normalized_line.gsub(/\s+/, " ")
    end

    include OutputSanitizer

    def recent_timeout_output(agent_run, since:, prompt:)
      return "" if since.blank?

      chunks = agent_run.agent_run_logs
        .where(log_type: %w[stdout stderr])
        .where("created_at >= ?", since)
        .order(created_at: :desc, id: :desc)
        .limit(TIMEOUT_RATE_LIMIT_LOG_LIMIT)
        .pluck(:content)

      # Precompute normalized prompt lines once rather than re-parsing per chunk.
      normalized_prompt = normalize_output_text(prompt)
      prompt_lines = if normalized_prompt.present?
        normalized_prompt.each_line.map do |line|
          normalize_output_line(line, strip_prompt_prefixes: true)
        end.reject(&:blank?).to_set
      else
        Set.new
      end

      normalized_chunks = chunks.filter_map do |chunk|
        stripped = strip_prompt_echo_with(chunk, prompt, normalized_prompt, prompt_lines).strip
        next if stripped.blank?

        stripped
      end

      # Join chunks with spaces so patterns can match across chunk
      # boundaries (e.g. "Free tier" + " limit reached"). A keyword split
      # mid-word across chunks (e.g. "quo" + "ta exceeded") would produce
      # "quo ta exceeded" and miss the match — acceptably unlikely in practice.
      normalized_chunks.reverse.join(" ")
    end

    # Variant of strip_prompt_echo that accepts precomputed prompt data
    # to avoid re-parsing per chunk in hot loops.
    def strip_prompt_echo_with(output, prompt, normalized_prompt, prompt_lines)
      output = normalize_output_text(output)
      return output if output.blank? || normalized_prompt.blank?

      sanitized_output = output.gsub(prompt, "")
      sanitized_output.each_line.filter_map do |line|
        normalized_line = normalize_output_line(line, strip_prompt_prefixes: true)
        next if normalized_line.blank? || prompt_lines.include?(normalized_line)

        line.rstrip
      end.join("\n").strip
    end

    def rate_limit_reset_at(provider_key, output)
      harness_provider = harness_provider_for(provider_key)
      parsed_reset = harness_provider.parse_rate_limit_reset(output.to_s) ||
        harness_provider.parse_rate_limit_reset(normalized_rate_limit_reset_text(output)) ||
        1.hour.from_now
      parsed_reset > Time.current ? parsed_reset : 1.hour.from_now
    rescue AgentHarness::ConfigurationError, KeyError
      1.hour.from_now
    end

    def harness_provider_for(provider_key)
      app_provider_key = ProviderSupport.provider_key_for_agent_type(provider_key)
      harness_key = ProviderSupport.harness_provider_key_for(app_provider_key).to_sym
      AgentHarness.provider(harness_key)
    end

    CODEX_SANDBOX_ABORT_PATTERNS = [
      /bwrap.*no permissions/i,
      /no permissions to create a new namespace/i,
      /unprivileged.*namespace/i
    ].freeze

    def aggregated_abort_patterns
      base = ProviderSupport.aggregated_error_classification_patterns(:abort)
      (base + CODEX_SANDBOX_ABORT_PATTERNS).uniq
    end

    def track_harness_tokens(agent_run, provider_candidate, provider_key, user, result, execution_started_at)
      response =
        begin
          parse_harness_response(provider_candidate, provider_key, user, result, execution_started_at)
        rescue => e
          logger.warn(
            message: "agent_execution.token_usage_parse_failed",
            agent_run_id: agent_run.id,
            provider: provider_key.to_s,
            error_class: e.class.name,
            error: e.message
          )
          return
        end

      AgentRuns::TrackHarnessTokens.call(
        agent_run: agent_run,
        response: response,
        proxy_scope: token_usage_scope_for_attempt(agent_run, execution_started_at)
      )
    end

    def token_usage_scope_for_attempt(agent_run, execution_started_at)
      scope = agent_run.token_usages
      return scope unless execution_started_at

      scope.where("created_at >= ?", execution_started_at)
    end

    def parse_harness_response(provider_candidate, provider_key, user, result, execution_started_at)
      harness_provider = harness_response_provider(provider_candidate, provider_key, user)
      command_result = AgentHarness::CommandExecutor::Result.new(
        stdout: result[:stdout],
        stderr: result[:stderr],
        exit_code: result[:exit_code],
        duration: harness_duration(execution_started_at)
      )
      response = parse_provider_output(harness_provider, command_result)
      apply_runtime_model(response, provider_candidate, user)
    end

    # Calls the provider's protected parse_response to convert raw container
    # output into an AgentHarness::Response. This uses send() because
    # agent-harness only exposes parsing through send_message (which executes
    # the CLI), but container runs have already executed externally.
    # TODO: replace with a public parse_container_output method in the
    # agent-harness provider interface (upstream).
    def parse_provider_output(provider, command_result)
      parse_options = { duration: command_result.duration }
      # Detect json_output_requested support from the method signature
      # rather than checking for a specific provider class.
      if provider.method(:parse_response).parameters.any? { |_, name| name == :json_output_requested }
        parse_options[:json_output_requested] = true
      end
      provider.send(:parse_response, command_result, **parse_options)
    end

    def harness_response_provider(provider_candidate, provider_key, user)
      app_provider_key = ProviderSupport.provider_key_for_agent_type(provider_key)
      harness_key = ProviderSupport.harness_provider_key_for(app_provider_key).to_sym
      klass = AgentHarness.provider_class(harness_key)
      config = harness_response_config(harness_key, provider_candidate, user)
      # Pass a no-op executor to satisfy providers whose initializer requires
      # one for execution. This instance is only used for parse_response, so
      # the executor is never invoked.
      klass.new(executor: NULL_EXECUTOR, config: config)
    end

    def harness_response_config(harness_key, provider_candidate, user)
      config = AgentHarness.build_config(harness_key)
      config.externally_sandboxed = true
      config.model = provider_runtime_model(provider_candidate, user)
      config
    end

    def apply_runtime_model(response, provider_candidate, user)
      model = provider_runtime_model(provider_candidate, user)
      return response if model.blank? || response.model == model

      AgentHarness::Response.new(
        output: response.output,
        exit_code: response.exit_code,
        duration: response.duration,
        provider: response.provider,
        model: model,
        tokens: response.tokens,
        metadata: response.metadata,
        error: response.error
      )
    end

    def provider_runtime_model(provider_candidate, user)
      provider_entry_for(provider_candidate, user)&.agent_harness_provider_runtime&.model
    end

    def harness_duration(execution_started_at)
      return 0.0 unless execution_started_at

      Time.current - execution_started_at
    end

    def normalized_rate_limit_reset_text(output)
      output.to_s
        .gsub(/retry.?after:?\s*(\d+)(?!\s*s)/i, 'retry after \1s')
        .gsub(/reset.?at:?\s*(\d+)/i, 'reset at \1')
    end

    def review_threads_already_addressed?(stdout:, stderr:, prompt:)
      signal_present?(strip_prompt_echo(stdout, prompt)) ||
        signal_present?(strip_prompt_echo(stderr, prompt))
    end

    def signal_present?(output)
      marker = Prompts::BuildForPr::ALREADY_ADDRESSED_MARKER
      output.to_s.each_line.any? { |line| line.strip == marker }
    end

    # Runs a block while sending periodic heartbeats from the activity's
    # execution thread. The activity context is thread/fiber-local, so
    # heartbeats must be emitted from the calling thread — not a background
    # thread. We therefore run the wrapped work in a background thread and
    # heartbeat from the calling (activity) thread while waiting for it to
    # complete.
    #
    # The interval (default 30s) is well under the 120s heartbeat timeout
    # configured on the workflow side, giving plenty of margin.
    HEARTBEAT_INTERVAL = 30

    def with_periodic_heartbeat(*details, interval: HEARTBEAT_INTERVAL, agent_run: nil)
      context = Temporalio::Activity::Context.current_or_nil
      return yield unless context

      tenant_account_id = Current.account&.id

      # Wrap the worker thread in Rails executor and ActiveRecord connection
      # pool management. The executor handles autoloading/reloading and the
      # with_connection block ensures the DB connection is checked out only
      # for the duration of the work and returned to the pool afterward,
      # preventing connection-pool exhaustion from long-running activities.
      worker = Thread.new do
        executor = Rails.application.executor if defined?(Rails) && Rails.respond_to?(:application) && Rails.application.respond_to?(:executor)
        work = proc { yield }

        db_scoped = proc do
          if defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:connection_pool)
            ActiveRecord::Base.connection_pool.with_connection { work.call }
          else
            work.call
          end
        end

        tenant_scoped = proc do
          if tenant_account_id
            tenant_account = TenantContext.with_system_access { Account.find_by(id: tenant_account_id) }
            if tenant_account
              TenantContext.with(tenant_account, &db_scoped)
            else
              TenantContext.with_system_access(&db_scoped)
            end
          else
            TenantContext.with_system_access(&db_scoped)
          end
        end

        if executor
          executor.wrap(&tenant_scoped)
        else
          tenant_scoped.call
        end
      end
      worker.report_on_exception = false
      canceled = false
      interrupted = false
      begin
        # Periodically heartbeat while the worker thread is still running.
        until worker.join(interval)
          begin
            context.heartbeat(*details)
            check_infinite_loop!(agent_run) if agent_run
          rescue Temporalio::Error::CanceledError
            canceled = true
            raise
          rescue InfiniteLoopError
            # Mark as interrupted so the ensure block terminates the
            # worker instead of joining it (which would re-raise the
            # worker's Interrupt and mask InfiniteLoopError).
            interrupted = true
            raise
          rescue StandardError
            # Best-effort; next iteration will retry.
          end
        end
      ensure
        # On cancellation, give the worker a short window to finish rather
        # than blocking indefinitely — this allows the activity to shut
        # down promptly during worker shutdown or workflow cancellation.
        if canceled
          worker.join(5)
          if worker.alive?
            # Use Thread#raise instead of Thread#kill so that ensure blocks
            # in the worker (e.g., Docker exec teardown) still execute.
            worker.raise(Interrupt)
            worker.join(5)
            # Last resort if the thread is stuck in an uninterruptible call.
            worker.kill if worker.alive?
          end
        elsif interrupted
          # Worker is still running — send Interrupt so the container
          # stops, then wait briefly for cleanup.
          #
          # NOTE: Thread.raise(Interrupt) is a best-effort signal here.
          # Containers::Provision#execute uses a watchdog that stops the
          # container to unblock blocking I/O (Thread.raise is unreliable
          # with Excon's blocking reads). For infinite-loop termination
          # the container exec has typically already produced output and
          # returned, so the Interrupt suffices. If the exec is mid-stream,
          # the container's own wall-clock timeout will eventually stop it.
          # A more robust approach would accept a cancellation proc to
          # directly stop the container; tracked for future improvement.
          worker.raise(Interrupt) if worker.alive?
          # Poll instead of worker.join — Interrupt inherits from
          # SignalException (not StandardError), so Thread#join can
          # propagate it to the calling thread and mask the
          # InfiniteLoopError already in flight. Thread#value has the
          # same issue. Polling with alive? avoids both problems.
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          sleep(0.05) while worker.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          worker.kill if worker.alive?
        else
          worker.join
        end
      end

      # Thread#value re-raises the original exception with its backtrace
      # intact, unlike manual capture-and-reraise which replaces the
      # backtrace with this method's call site. Skip when the worker was
      # intentionally interrupted (infinite loop) — re-raising the
      # Interrupt would mask the InfiniteLoopError already propagating.
      worker.value unless interrupted
    end

    def build_command(command_context, prompt)
      provider_entry = provider_entry_for(command_context.provider_candidate, command_context.user)

      if provider_entry&.agent_harness_runtime?
        harness_runtime_command(provider_entry, prompt)
      elsif provider_entry&.requires_direct_outbound?
        plan = harness_execution_plan_for(command_context.provider, prompt, provider_entry: provider_entry)
        provider_entry.direct_outbound_exec_command(command_prefix: plan.command[0..-2], prompt: prompt)
      elsif provider_entry&.api_key?
        plan = harness_execution_plan_for(command_context.provider, prompt)
        api_key_auth_command(provider_entry, plan.command[0..-2], prompt)
      elsif ProviderSupport.subscription_auth_unset_vars_for(command_context.provider).any?
        plan = harness_execution_plan_for(command_context.provider, prompt)
        subscription_auth_command(command_context.provider, plan.command[0..-2], prompt)
      else
        plan = harness_execution_plan_for(command_context.provider, prompt)
        plan.command
      end
    end

    # Builds a harness execution plan for a provider identified by its
    # app-level key. Delegates command construction to agent-harness so
    # provider CLI flag semantics are owned upstream.
    #
    # The plan is cached per (provider_key, prompt, harness_runtime?)
    # tuple so that multiple branches within build_command can share
    # the same capture without re-running the harness provider. The
    # boolean discriminator ensures calls with and without a
    # provider_entry that has an agent_harness_provider_runtime are
    # never conflated.
    def harness_execution_plan_for(provider_key, prompt, provider_entry: nil)
      @harness_plan_cache ||= {}
      cache_key = [ provider_key, prompt, provider_entry&.agent_harness_provider_runtime.present? ]
      return @harness_plan_cache[cache_key] if @harness_plan_cache.key?(cache_key)

      options = { dangerous_mode: true }

      @harness_plan_cache[cache_key] = if provider_entry&.agent_harness_provider_runtime
        Providers::HarnessExecutionPlan.call(
          provider: provider_entry,
          prompt: prompt,
          options: options
        )
      else
        Providers::HarnessExecutionPlan.for_provider_key(
          provider_key: ProviderSupport.provider_key_for_agent_type(provider_key),
          prompt: prompt,
          options: options
        )
      end
    end

    def command_env_for(command_context, prompt)
      provider_entry = provider_entry_for(command_context.provider_candidate, command_context.user)
      return direct_outbound_execution_plan(provider_entry, prompt).env if provider_entry&.agent_harness_runtime?
      return {} unless provider_entry

      env = {}
      env.merge!(provider_entry.direct_outbound_exec_env) if provider_entry.requires_direct_outbound?
      env.merge!(api_key_command_env(provider_entry)) if provider_entry.api_key?
      env
    end

    def command_preparation_for(command_context, prompt)
      provider_entry = provider_entry_for(command_context.provider_candidate, command_context.user)
      return nil unless provider_entry&.agent_harness_runtime?

      direct_outbound_execution_plan(provider_entry, prompt).preparation
    end

    # Combines two ExecutionPreparation instances by concatenating their
    # file_writes. Returns whichever is non-nil when only one is present.
    def merge_preparations(base, additional)
      return additional if base.nil?
      return base if additional.nil?

      AgentHarness::ExecutionPreparation.new(
        file_writes: base.file_writes + additional.file_writes
      )
    end

    def direct_outbound_execution_plan(provider_entry, prompt)
      @direct_outbound_execution_plan_cache ||= {}
      cache_key = [ provider_entry.id, prompt ]
      return @direct_outbound_execution_plan_cache[cache_key] if @direct_outbound_execution_plan_cache.key?(cache_key)

      @direct_outbound_execution_plan_cache[cache_key] = Providers::HarnessExecutionPlan.call(
        provider: provider_entry,
        prompt: prompt
      )
    end

    def provider_command_key(provider_candidate, agent_run, user = nil)
      provider_entry = provider_entry_for(provider_candidate, user)
      return provider_candidate unless provider_entry
      return "claude_code" if agent_run&.provider_id == provider_entry.id && provider_entry.provider_key == "claude" && agent_run.agent_type == "claude_code"

      provider_entry.provider_key
    end

    def state_key_for(provider_candidate, provider, user = nil)
      provider_entry = provider_entry_for(provider_candidate, user)
      return provider_entry.routing_key if provider_entry&.api_key?
      return provider_entry.provider_key if provider_entry

      canonical_provider(provider)
    end

    def provider_entry_for(provider_candidate, user)
      return provider_candidate if provider_candidate.is_a?(Provider)
      return nil unless user
      return nil unless Provider.routing_key?(provider_candidate)

      @provider_entry_cache ||= {}
      cache_key = [ user.id, provider_candidate ]
      return @provider_entry_cache[cache_key] if @provider_entry_cache.key?(cache_key)

      @provider_entry_cache[cache_key] = Provider.for_identifier(user, provider_candidate)
    end

    def deduplicate_provider_candidates(primary_provider:, fallback_providers:, user:)
      providers = [ primary_provider ]
      seen = Set.new([ canonical_provider_candidate(primary_provider, user) ])

      Array(fallback_providers).each do |provider_candidate|
        canonical_candidate = canonical_provider_candidate(provider_candidate, user)
        next if seen.include?(canonical_candidate)

        seen << canonical_candidate
        providers << provider_candidate
      end

      providers.select do |provider_candidate|
        self.class.container_executable?(provider_command_key(provider_candidate, nil, user))
      end
    end

    def canonical_provider_candidate(provider_candidate, user)
      provider_entry = provider_entry_for(provider_candidate, user)
      return provider_entry.provider_key if provider_entry

      canonical_provider(provider_candidate)
    end

    def load_rate_limit_fallbacks(user)
      return {} unless user
      return {} if user.new_record?

      executable_keys = ProviderSupport.container_executable_provider_keys

      user.providers.api_key.rate_limit_fallback.for_fallback
        .where(provider_key: executable_keys)
        .ordered
        .group_by(&:provider_key)
        .transform_values { |entries| entries.map(&:routing_key) }
    end

    def insert_rate_limit_fallbacks!(providers:, index:, provider_candidate:, provider:, agent_run:)
      fallback_candidates = rate_limit_fallback_candidates_for(provider_candidate, provider, providers)
      return if fallback_candidates.empty?

      logger.info(
        message: "agent_execution.rate_limit_fallback_available",
        provider: canonical_provider(provider),
        agent_run_id: agent_run.id,
        fallback_providers: fallback_candidates
      )

      providers.insert(index + 1, *fallback_candidates)
    end

    def rate_limit_fallback_candidates_for(provider_candidate, provider, providers)
      @inserted_rate_limit_fallbacks ||= Set.new

      canonical_key = canonical_provider(provider)
      configured = Array(@rate_limit_fallbacks&.fetch(canonical_key, []))
      return [] if configured.empty?

      already_scheduled = providers.to_set
      current_provider = provider_candidate.to_s

      configured.reject do |candidate|
        candidate == current_provider ||
          @inserted_rate_limit_fallbacks.include?(candidate) ||
          already_scheduled.include?(candidate)
      end.tap do |new_candidates|
        @inserted_rate_limit_fallbacks.merge(new_candidates)
      end
    end

    def simulated_provider_attempt_count(agent_run, providers, user)
      @rate_limit_fallbacks = load_rate_limit_fallbacks(user)
      @inserted_rate_limit_fallbacks = Set.new
      simulated_providers = providers.dup

      index = 0
      while index < simulated_providers.length
        provider_candidate = simulated_providers[index]
        provider = provider_command_key(provider_candidate, agent_run, user)
        fallback_candidates = rate_limit_fallback_candidates_for(provider_candidate, provider, simulated_providers)
        simulated_providers.insert(index + 1, *fallback_candidates) if fallback_candidates.any?
        index += 1
      end

      simulated_providers.size
    end

    # Returns a per-entry identifier suitable for persisting in
    # providers_attempted and final_provider. Uses the routing key for
    # API-key-backed entries so that multiple entries sharing the same
    # provider_key remain distinguishable; uses provider_key for
    # subscription entries so the value stays compatible with
    # matches_identifier?, effective_provider_sql, and dashboard
    # aggregations (which group by provider key, not agent_type).
    def provider_attempt_label(provider_candidate, agent_run, user)
      provider_entry = provider_entry_for(provider_candidate, user)
      return provider_entry.routing_key if provider_entry&.api_key?
      return provider_entry.provider_key if provider_entry
      provider_command_key(provider_candidate, agent_run, user)
    end

    def provider_attempt_labels(providers, agent_run, user)
      providers.map do |provider_candidate|
        provider_entry = provider_entry_for(provider_candidate, user)
        if provider_entry&.display_name
          provider_entry.display_name
        elsif Provider.routing_key?(provider_candidate)
          "Deleted provider entry"
        else
          provider_command_key(provider_candidate, agent_run, user)
        end
      end
    end

    class << self
      def provider_attempt_count_for_run(agent_run:, user_settings:)
        return 1 unless user_settings

        activity = new
        providers = activity.send(:build_provider_order, agent_run, user_settings)
        count = activity.send(:simulated_provider_attempt_count, agent_run, providers, user_settings.user)

        [ count, 1 ].max
      end
    end

    # Wraps a provider command so that, when subscription auth is active,
    # proxy-related env vars are unset and the CLI talks directly to the
    # provider. The prompt is passed as a positional parameter ($1) to
    # preserve multi-line content from augment_prompt_for_goal. The
    # unset-var list is shared with Providers::TestAgent via
    # ProviderSupport.subscription_auth_unset_vars_for.
    def subscription_auth_command(provider, command_prefix, prompt)
      base = command_prefix.shelljoin
      env_flag = "PAID_#{provider.upcase}_SUBSCRIPTION_AUTH"
      unset_flags = subscription_auth_unset_vars_for(provider)
        .map { |var| "-u #{var}" }
        .join(" ")

      script = "if [ \"$#{env_flag}\" = \"1\" ]; then env #{unset_flags} #{base} \"$1\"; else #{base} \"$1\"; fi"
      [ "sh", "-c", script, "--", prompt ]
    end

    def api_key_auth_command(provider_entry, command_prefix, prompt)
      base = command_prefix.shelljoin
      env_assignments = api_key_env_var_names_for(provider_entry)
        .map { |var| %(#{var}="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN") }
        .join(" ")
      header_assignments = api_key_proxy_header_assignments_for(provider_entry)
        .join(" ")

      script = "env #{header_assignments} #{env_assignments} #{base} \"$1\""
      [ "sh", "-c", script, "--", prompt ]
    end

    def api_key_command_env(provider_entry)
      { "PAID_PROVIDER_ID" => provider_entry.id.to_s }
    end

    def api_key_env_var_names_for(provider_entry)
      harness_provider_for(provider_entry.provider_key).api_key_env_var_names
    end

    def api_key_proxy_header_assignments_for(provider_entry)
      case provider_entry.provider_key
      when "gemini"
        [
          %(GOOGLE_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID"),
          %(GEMINI_CLI_CUSTOM_HEADERS="X-Agent-Run-Id: $AGENT_RUN_ID, X-Proxy-Token: $PROXY_TOKEN, X-Paid-Provider-Id: $PAID_PROVIDER_ID")
        ]
      when "codex"
        [ %(OPENAI_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID") ]
      when "claude", "cursor", "aider"
        [
          %(ANTHROPIC_BASE_URL="$PAID_PROXY_URL/api/proxy/anthropic"),
          %(ANTHROPIC_HEADER_X_AGENT_RUN_ID="$AGENT_RUN_ID"),
          %(ANTHROPIC_HEADER_X_PROXY_TOKEN="$PROXY_TOKEN"),
          %(ANTHROPIC_HEADER_X_PAID_PROVIDER_ID="$PAID_PROVIDER_ID")
        ]
      else
        []
      end
    end

    def subscription_auth_unset_vars_for(provider)
      ProviderSupport.subscription_auth_unset_vars_for(provider)
    end

    # Wraps the harness execution plan command with `env -u` to strip
    # proxy-specific headers inherited from container startup so they
    # are not forwarded to the real provider API.
    def harness_runtime_command(provider_entry, prompt)
      plan = direct_outbound_execution_plan(provider_entry, prompt)
      unset_vars = ProviderSupport.harness_runtime_unset_vars_for(provider_entry.provider_key)
      ProviderSupport.command_with_unset_env(plan.command, unset_vars)
    end

    def capture_head_sha(container_service, agent_run)
      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )
      git_ops.head_sha
    rescue => e
      logger.warn(
        message: "agent_execution.capture_head_sha_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      nil
    end

    # Commits any uncommitted changes the agent left behind.
    # Agents may edit files without running git add/commit;
    # this ensures those edits are captured before push.
    def commit_uncommitted_changes(agent_run)
      return unless agent_run.container_id.present?

      committed = with_change_detection_retry(agent_run, operation: "commit_uncommitted_changes") do
        container_service = reconnect_container(agent_run)
        git_ops = Containers::GitOperations.new(
          container_service: container_service,
          agent_run: agent_run
        )

        git_ops.commit_uncommitted_changes
      end

      agent_run.log!("system", "Auto-committed uncommitted agent changes") if committed
    end

    # Evaluates pre-commit requirements for the agent run.
    # Returns a hash with :passed, :results, and :blocking keys.
    def evaluate_pre_commit_requirements(agent_run)
      PreCommitRequirements::Evaluate.call(agent_run: agent_run)
    rescue => e
      logger.warn(
        message: "agent_execution.pre_commit_evaluation_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      # Fail closed: treat evaluation crashes as blocking so configured
      # enforcement is never silently bypassed.
      {
        passed: false,
        results: [ { type: "error", message: "Pre-commit evaluation failed: #{e.message}" } ],
        blocking: true
      }
    end

    def check_for_changes(agent_run, pre_agent_sha)
      return false unless agent_run.container_id.present?

      with_change_detection_retry(agent_run, operation: "check_for_changes") do
        container_service = reconnect_container(agent_run)

        git_ops = Containers::GitOperations.new(
          container_service: container_service,
          agent_run: agent_run
        )

        if pre_agent_sha.present?
          git_ops.has_changes_since?(pre_agent_sha)
        else
          git_ops.has_changes?
        end
      end
    end

    def with_change_detection_retry(agent_run, operation:)
      attempt = 0

      begin
        attempt += 1
        yield(attempt)
      rescue StandardError => e
        transient = transient_container_error?(e)

        if transient && attempt < CHANGE_DETECTION_MAX_ATTEMPTS
          logger.warn(
            message: "agent_execution.change_detection_retry",
            agent_run_id: agent_run.id,
            operation: operation,
            attempt: attempt,
            max_attempts: CHANGE_DETECTION_MAX_ATTEMPTS,
            error_class: e.class.name,
            error: e.message
          )
          sleep(CHANGE_DETECTION_RETRY_BACKOFF * attempt)
          retry
        end

        logger.error(
          message: "agent_execution.change_detection_failed",
          agent_run_id: agent_run.id,
          operation: operation,
          attempt: attempt,
          max_attempts: CHANGE_DETECTION_MAX_ATTEMPTS,
          transient: transient,
          error_class: e.class.name,
          error: e.message
        )
        raise Temporalio::Error::ApplicationError.new(
          "Post-run #{operation} failed after #{attempt} attempts: #{e.class}: #{e.message}",
          type: POST_RUN_BOOKKEEPING_ERROR_TYPE,
          non_retryable: true
        )
      end
    end

    def transient_container_error?(error)
      return true if error_or_cause_matches?(error, Containers::Provision::ExecutionError)
      return true if reconnect_failure?(error)

      current = error

      while current
        return true if [
          Docker::Error::DockerError,
          Timeout::Error,
          EOFError,
          Errno::ECONNREFUSED,
          Errno::EHOSTUNREACH,
          Errno::ECONNRESET,
          Errno::EPIPE,
          Errno::ETIMEDOUT,
          SocketError
        ].any? { |klass| current.is_a?(klass) }
        return true if current.class.ancestors.any? { |ancestor| ancestor.name == "Excon::Error" }
        return true if %w[Net::OpenTimeout Net::ReadTimeout].include?(current.class.name)

        break unless current.respond_to?(:cause)
        current = current.cause
      end

      false
    end

    def reconnect_failure?(error)
      error_or_cause_matches?(error, Containers::Provision::ProvisionError) do |candidate|
        candidate.message.start_with?("Failed to reconnect to container:")
      end
    end

    def container_dead_after_exec_error?(agent_run, error)
      return false unless error.message.match?(/container.*is not running/i)
      return false if agent_run.container_id.blank?

      container_service = reconnect_container(agent_run) rescue nil
      return false unless container_service

      !container_service.container_running?
    end

    def container_exit_diagnostics(container_service)
      container = container_service.container
      return "Container object unavailable." unless container

      container.refresh!
      state = container.info["State"] || {}
      exit_code = state["ExitCode"]
      oom_killed = state["OOMKilled"]
      error_msg = state["Error"]
      finished_at = state["FinishedAt"]

      reasons = []
      reasons << "OOM killed" if oom_killed
      reasons << "exit code #{exit_code}" if exit_code && exit_code != 0
      reasons << "error: #{error_msg}" if error_msg.present?
      reasons << "finished at #{finished_at}" if finished_at.present?

      "Container state: #{reasons.join(', ').presence || 'unknown'}"
    rescue Docker::Error::DockerError => e
      "Could not inspect container: #{e.message}"
    end

    def error_or_cause_matches?(error, klass, &)
      current = error

      while current
        return true if current.is_a?(klass) && (!block_given? || yield(current))

        break unless current.respond_to?(:cause)
        current = current.cause
      end

      false
    end

    def augment_prompt_for_goal(agent_run, prompt)
      if agent_run.create_issue_goal?
        augment_prompt_for_issue_goal(agent_run, prompt)
      elsif agent_run.enhance_issue_goal?
        augment_prompt_for_enhance_issue_goal(agent_run, prompt)
      elsif agent_run.review_goal?
        augment_prompt_for_review_goal(agent_run, prompt)
      else
        prompt
      end
    end

    # Goal-augmentation prompts.
    #
    # The active templates live in db/seeds/prompts.rb under the slugs
    # `goal.create_github_issue` and `goal.review_pull_request`. The
    # FALLBACK_* constants below are the safety net used when the seeded
    # row is missing or deactivated; they must stay in sync with the seeds.
    # spec/db/seeds_prompts_spec.rb asserts both pairs match.
    ISSUE_GOAL_PROMPT_SLUG = "goal.create_github_issue"

    FALLBACK_ISSUE_GOAL_PROMPT = <<~'AUGMENTED'
      {{base_prompt}}

      ---
      IMPORTANT: Your goal is to CREATE A GITHUB ISSUE, not to write code or create a PR.

      You have access to the GitHub API via a proxy. Use curl to create the issue.

      IMPORTANT: Do NOT pass JSON inline with a single-quoted -d '...'. The body will contain
      markdown with apostrophes (single quotes) and possibly newlines that break shell quoting.
      Instead, write the JSON payload to a temporary file and use --data-binary @file:

      ```bash
      tmpfile=$(mktemp)
      cat > "$tmpfile" <<'ISSUE_JSON'
      {
        "title": "Issue title",
        "body": "Issue description with `code` and apostrophes",
        "labels": []
      }
      ISSUE_JSON
      curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/issues" \
        -H "Content-Type: application/json" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN" \
        --data-binary @"$tmpfile"
      rm -f "$tmpfile"
      ```

      Available endpoints:
      - GET  $GITHUB_API_URL/repos/{{repo}}/issues — list issues
      - GET  $GITHUB_API_URL/repos/{{repo}}/issues/{number} — get issue
      - POST $GITHUB_API_URL/repos/{{repo}}/issues — create issue
      - PATCH $GITHUB_API_URL/repos/{{repo}}/issues/{number} — update issue
      - POST $GITHUB_API_URL/repos/{{repo}}/issues/{number}/comments — add comment
      - POST $GITHUB_API_URL/repos/{{repo}}/issues/{number}/labels — add labels

      Do NOT push code or create a pull request. Only create the GitHub issue.
    AUGMENTED

    REVIEW_GOAL_PROMPT_SLUG = "goal.review_pull_request"

    # The "Generated no new comments." phrase in the template below is
    # matched (case-insensitive) by
    #   ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN = /generated no (?:new )?comments/i
    # which is how Paid recognizes a clean review and stops the review loop.
    # spec/db/seeds_prompts_spec.rb has a coupling spec — if you change the
    # matcher pattern, update the seed AND this constant together or the spec
    # will fail.
    FALLBACK_REVIEW_GOAL_PROMPT = <<~'AUGMENTED'
      {{base_prompt}}

      ---
      IMPORTANT: Your goal is to REVIEW A PULL REQUEST, not to write code, create issues, or create PRs.

      Review PR #{{pr_number}} in {{repo}}. Examine the code changes and post a review on the PR.
      Your review will be posted to GitHub under the `paid-code-reviewer[bot]`
      account, so write in a direct review voice and do not mention that you
      are unable to post as a bot.

      You have access to the repository code (already cloned). To examine the code changes, either:
      - Use the GitHub API (via the proxy) to retrieve the PR's `/pulls/{{pr_number}}/files` patches and review those diffs; or
      - From the cloned repo, run an explicit diff against the PR base, for example:
        `git fetch origin` then `git diff "$(git merge-base HEAD origin/main)"...HEAD`
        (replace `main` with the PR's actual base branch if different).
      You also have access to the GitHub API via a proxy for posting review comments.

      You can search the project's knowledge base to look up existing code,
      symbols, routes, and patterns before deciding whether a finding is valid:

      ```bash
      curl -s --connect-timeout 10 --max-time 30 "$KNOWLEDGE_SEARCH_URL?q=review+pattern" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN"
      ```

      Use this when the PR diff or linked issue raises a question that existing
      code patterns can answer. Do not ask for clarification or report a finding
      until you have checked whether the knowledge base answers it.

      You may run targeted validation when it is useful for review confidence.
      Before running Ruby/Rails commands such as `bin/rspec`, run
      `BUNDLE_PATH=/tmp/bundle BUNDLE_APP_CONFIG=/tmp/bundle-config BUNDLE_FROZEN=true bundle check || BUNDLE_PATH=/tmp/bundle BUNDLE_APP_CONFIG=/tmp/bundle-config BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3`
      so the fresh review checkout has the bundled gems it needs in a writable
      path outside the repository without changing the lockfile. If dependency
      installation or test execution still
      fails because of missing network access, services, or environment
      constraints, mention that specific blocker in the review body.

      Review the code for:
      1. **Performance** — inefficient algorithms, N+1 queries, unnecessary allocations, missing caching
      2. **Security** — SQL injection, XSS, insecure deserialization, secrets in code
      3. **Best practices** — language/framework idioms, error handling, naming
      4. **Project code style** — adherence to existing conventions, indentation, file organization
      5. **Scope violations** — changes unrelated to the linked issue, unnecessary refactoring, feature creep
      6. **Issue linkage** — verify the PR actually addresses the issue it claims to fix

      # Comment policy — read carefully

      Inline comments are reserved **exclusively for actionable changes**: security,
      correctness, performance, scope, or style problems that require the author to
      edit code. Do **not** post praise-only comments, "looks good" notes, "nice
      refactor" remarks, or any inline comment that does not request a concrete
      change. If you have nothing actionable to say about a hunk, do not comment on it.

      A clean PR with zero issues is a valid and expected outcome. Do not invent
      nitpicks to justify having posted a review.

      Use GitHub's suggestion block syntax for concrete fixes:
      ````
      ```suggestion
      corrected code here
      ```
      ````

      MANDATORY: When you find actionable issues (Case A), each issue MUST include an
      inline comment in the "comments" array with a specific "path" and "line" number.
      A review body describing problems WITHOUT corresponding inline comments is
      incomplete. If you cannot identify specific file paths and line numbers, do not
      include that issue in the review.

      Post your review using the GitHub API proxy.

      IMPORTANT: Do NOT pass the review JSON inline with a single-quoted `-d '...'`.
      Review bodies and inline comments contain markdown, suggestion blocks, newlines,
      and apostrophes — inlining that payload breaks shell quoting and produces
      malformed JSON (invalid control characters inside strings) that Rails rejects
      before the request ever reaches GitHub. Always write the review JSON to a
      temporary file and submit it with `--data-binary @file`.

      ```bash
      # Get PR details (metadata and links)
      curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN"

      # Get PR files
      curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/files" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN"

      # Case A — actionable issues found: post a review with inline comments.
      # MANDATORY: When you find actionable issues, each issue MUST include an
      # inline comment in the "comments" array with a specific "path" and
      # "line" number. A review body that describes problems without matching
      # inline comments is incomplete. If you cannot identify a specific file
      # path and line number for an issue, do not include that issue in the review.
      # Note: "side" must be "RIGHT" (new code) or "LEFT" (deleted code).
      tmpfile=$(mktemp)
      cat > "$tmpfile" <<'REVIEW_JSON'
      {
        "body": "Overall summary of the actionable issues found",
        "event": "COMMENT",
        "comments": [
          {
            "path": "file.rb",
            "line": 10,
            "side": "RIGHT",
            "body": "Actionable change request on this line"
          }
        ]
      }
      REVIEW_JSON
      curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews" \
        -H "Content-Type: application/json" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN" \
        --data-binary @"$tmpfile"
      rm -f "$tmpfile"

      # Case B — clean PR, no actionable issues: post a single review with an EMPTY
      # comments array and a body that begins with the EXACT phrase
      # "Generated no new comments." Include the exact HTML marker
      # "<!-- paid-review-clean -->" somewhere in the body. These are the
      # signals Paid uses to mark the review as clean and stop the review loop.
      # Do NOT paraphrase either signal.
      tmpfile=$(mktemp)
      cat > "$tmpfile" <<'REVIEW_JSON'
      {
        "body": "Generated no new comments. The PR looks ready as-is. <!-- paid-review-clean -->",
        "event": "COMMENT",
        "comments": []
      }
      REVIEW_JSON
      curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews" \
        -H "Content-Type: application/json" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN" \
        --data-binary @"$tmpfile"
      rm -f "$tmpfile"
      ```

      If you ever need to send any other JSON payload to the proxy (for example a
      follow-up issue comment), apply the same pattern: write the body to a temp
      file and submit with `--data-binary @file`. Never inline JSON with `-d '...'`.

      # Pre-submission verification

      Before submitting your review, verify your JSON payload:
      - Case A: "comments" array is NON-EMPTY, each entry has "path", "line", and "body"
      - Case B: body starts with EXACTLY "Generated no new comments." and "comments" is []

      IMPORTANT: You MUST post exactly one PR review via the
      `/pulls/{{pr_number}}/reviews` endpoint — either Case A (with inline
      actionable comments) or Case B (clean review). This is how your review is
      tracked as complete. Standalone PR comments via
      `/issues/{{pr_number}}/comments` do NOT satisfy the review requirement.

      Available endpoints:
      - GET  $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}} — get PR details
      - GET  $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/files — list changed files
      - POST $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews — create review (REQUIRED, exactly once)
      - GET  $GITHUB_API_URL/repos/{{repo}}/issues/{number} — get linked issue details

      Do NOT push code, create issues, or create new pull requests. Only post the review on PR #{{pr_number}}.
    AUGMENTED

    ENHANCE_ISSUE_GOAL_PROMPT_SLUG = "goal.enhance_issue"

    FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT = <<~'AUGMENTED'
      {{base_prompt}}

      ---
      IMPORTANT: Your goal is to ENHANCE AN EXISTING ISSUE by adding context or asking clarifying questions.
      Do NOT write code, create PRs, or create new issues.

      Read issue #{{issue_number}} in {{repo}} — its description and all comments — then add a SINGLE comment that either:

      1. **Provides implementation context** — relevant files, architecture notes, suggested approach,
         related patterns — if the issue has enough information to be implemented.
      2. **Asks specific clarifying questions** — if the issue is ambiguous, missing acceptance criteria,
         or has unstated constraints that need answers before implementation can begin.

      You can search the project's knowledge base to look up existing code,
      symbols, routes, and patterns before asking questions:

      ```bash
      curl -s --connect-timeout 10 --max-time 30 "$KNOWLEDGE_SEARCH_URL?q=sortable+column+dashboard" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN"
      ```

      Use this to check whether something already exists in the codebase before
      asking a clarifying question. If the knowledge base answers your question,
      provide the answer as implementation context instead.

      Use curl to interact with the GitHub API via the proxy. Write JSON payloads to a temp file to avoid
      shell quoting issues:

      ```bash
      tmpfile=$(mktemp)
      cat > "$tmpfile" <<'COMMENT_JSON'
      {
        "body": "Your comment in markdown"
      }
      COMMENT_JSON
      curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/issues/{{issue_number}}/comments" \
        -H "Content-Type: application/json" \
        -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
        -H "X-Proxy-Token: $PROXY_TOKEN" \
        --data-binary @"$tmpfile"
      rm -f "$tmpfile"
      ```

      Available endpoints:
      - GET  $GITHUB_API_URL/repos/{{repo}}/issues/{{issue_number}} — get issue details
      - GET  $GITHUB_API_URL/repos/{{repo}}/issues/{{issue_number}}/comments — list comments
      - POST $GITHUB_API_URL/repos/{{repo}}/issues/{{issue_number}}/comments — add comment

      Do NOT push code, create issues, or create pull requests. Only add a comment to issue #{{issue_number}}.
    AUGMENTED

    def augment_prompt_for_issue_goal(agent_run, prompt)
      # When custom_prompt is set (PromptVersion path), BuildForIssue is
      # bypassed and knowledge context is not yet present — inject it here
      # so configuration experiments can participate.  When BuildForIssue
      # built the prompt it already injected knowledge with agent_run.
      if agent_run.custom_prompt.present? && agent_run.issue
        prompt = inject_knowledge_into_prompt(prompt, agent_run.issue, agent_run.project, agent_run)
      end

      vars = { base_prompt: prompt, repo: validated_repo_name(agent_run) }

      rendered = resolve_and_persist_goal_prompt(
        agent_run: agent_run,
        slug: ISSUE_GOAL_PROMPT_SLUG,
        variables: vars,
        fallback_template: FALLBACK_ISSUE_GOAL_PROMPT
      )

      maybe_assign_ab_test_variant(agent_run, ISSUE_GOAL_PROMPT_SLUG, rendered, vars)
    end

    def augment_prompt_for_review_goal(agent_run, prompt)
      pr_number = agent_run.source_pull_request_number
      raise Temporalio::Error::ApplicationError.new(
        "Review goal requires source_pull_request_number",
        type: "MissingPRNumber",
        non_retryable: true
      ) unless pr_number

      vars = {
        base_prompt: prompt,
        repo: validated_repo_name(agent_run),
        pr_number: pr_number.to_s
      }

      rendered = resolve_and_persist_goal_prompt(
        agent_run: agent_run,
        slug: REVIEW_GOAL_PROMPT_SLUG,
        variables: vars,
        fallback_template: FALLBACK_REVIEW_GOAL_PROMPT
      )

      maybe_assign_ab_test_variant(agent_run, REVIEW_GOAL_PROMPT_SLUG, rendered, vars)
    end

    def augment_prompt_for_enhance_issue_goal(agent_run, prompt)
      issue = agent_run.issue
      raise Temporalio::Error::ApplicationError.new(
        "Enhance-issue goal requires an associated issue",
        type: "MissingIssue",
        non_retryable: true
      ) unless issue

      prompt = inject_knowledge_into_prompt(prompt, issue, agent_run.project, agent_run)

      vars = {
        base_prompt: prompt,
        repo: validated_repo_name(agent_run),
        issue_number: issue.github_number.to_s
      }

      rendered = resolve_and_persist_goal_prompt(
        agent_run: agent_run,
        slug: ENHANCE_ISSUE_GOAL_PROMPT_SLUG,
        variables: vars,
        fallback_template: FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT
      )

      maybe_assign_ab_test_variant(agent_run, ENHANCE_ISSUE_GOAL_PROMPT_SLUG, rendered, vars)
    end

    def resolve_and_persist_goal_prompt(agent_run:, slug:, variables:, fallback_template:)
      prompt_version = Prompts::Resolve.call(slug: slug, project: agent_run.project)

      if prompt_version
        agent_run.update!(prompt_version: prompt_version) unless agent_run.prompt_version_id
        prompt_version.render(variables)
      else
        Rails.logger.warn(
          message: "prompts.render_fallback",
          slug: slug,
          project_id: agent_run.project_id,
          reason: "no_active_version"
        )
        Prompts::Render.interpolate(fallback_template, variables)
      end
    end

    def maybe_assign_ab_test_variant(agent_run, slug, rendered, vars)
      assignment = existing_ab_test_assignment(agent_run, slug)
      assignment ||= assign_running_ab_test(agent_run, slug)
      return rendered unless assignment

      variant_version = assignment.ab_test_variant.prompt_version
      agent_run.update!(prompt_version: variant_version)

      variant_version.render(vars)
    end

    def existing_ab_test_assignment(agent_run, slug)
      AbTestAssignment
        .joins(ab_test: :prompt)
        .includes(ab_test_variant: :prompt_version)
        .where(agent_run: agent_run, prompts: { slug: slug })
        .order(:id)
        .first
    end

    def assign_running_ab_test(agent_run, slug)
      prompt = Prompt.resolve(slug, project: agent_run.project)
      return nil unless prompt

      ab_test = prompt.ab_tests.running.first
      return nil unless ab_test

      AbTests::Assign.call(ab_test: ab_test, agent_run: agent_run)
    end

    def inject_knowledge_into_prompt(prompt, issue, project, agent_run)
      bundle = Knowledge::ContextBundle::Build.call(
        issue: issue,
        project: project,
        agent_run: agent_run,
        agent_run_id: agent_run.id
      )
      return prompt if bundle[:content].blank?

      "#{prompt}\n#{bundle[:content]}\n"
    end

    def validated_repo_name(agent_run)
      repo = agent_run.project.full_name
      unless repo.match?(%r{\A[A-Za-z0-9\-_.]+/[A-Za-z0-9\-_.]+\z})
        raise Temporalio::Error::ApplicationError.new(
          "Invalid repository name format: #{repo.inspect}",
          type: "InvalidRepoName",
          non_retryable: true
        )
      end
      repo
    end

    # Writes the given provider candidate's co-author trailer into the
    # container so the commit-msg hook uses it for subsequent intermediate
    # commits. When no provider record can be resolved from the candidate
    # (e.g. non-routing-key agent_type), the file is cleared so the hook
    # falls back to a no-op rather than silently using a stale trailer.
    def refresh_co_author_trailer(container_service, agent_run, provider_candidate, user)
      provider_record = resolve_provider_record_for_candidate(provider_candidate, user)
      Containers::GitOperations
        .new(container_service: container_service, agent_run: agent_run)
        .write_co_author_trailer(provider_record)
    end

    def resolve_provider_record_for_candidate(provider_candidate, user)
      provider_entry = provider_entry_for(provider_candidate, user)
      return provider_entry if provider_entry
      return nil unless user
      return nil if provider_candidate.blank?

      identifier = provider_candidate.to_s
      Provider.for_identifier(user, identifier) ||
        Provider.for_identifier(user, ProviderSupport.provider_key_for_agent_type(identifier))
    end

    def reconnect_container(agent_run)
      if agent_run.container_id.blank?
        raise Temporalio::Error::ApplicationError.new(
          "No container provisioned for agent run #{agent_run.id}",
          type: "ContainerNotProvisioned",
          non_retryable: true
        )
      end

      Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )
    end

    def agent_timeout
      AGENT_TIMEOUT_DEFAULT
    end
  end
end
