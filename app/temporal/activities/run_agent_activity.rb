# frozen_string_literal: true

require "shellwords"

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    include Containers::QualityHooks

    # Returns true if the given runner key can be executed inside the
    # container. Replaces the former AGENT_COMMANDS.key? check. Container
    # executability is gated by RunnerSupport::CONTAINER_EXECUTABLE_PROVIDER_KEYS
    # — runners not in that set are filtered out upstream (UserSetting,
    # ProvidersController) before reaching runner_order.
    def self.container_executable?(runner_key)
      key = AGENT_TYPE_TO_RUNNER.fetch(runner_key, runner_key)
      RunnerSupport.container_executable_runner_key?(key)
    end

    # Maps agent_type values to their canonical settings runner name.
    # Some agent types (e.g., "claude_code") share the same underlying runner as
    # a settings-level name ("claude"), so they should be deduplicated during fallback.
    AGENT_TYPE_TO_RUNNER = {
      "claude_code" => "claude"
    }.freeze

    # No-op executor for runner instances used only for response parsing.
    NULL_EXECUTOR = Object.new.tap do |obj|
      obj.define_singleton_method(:execute) { |*, **| raise "NULL_EXECUTOR: not meant for execution" }
    end.freeze

    # Patterns that indicate a rate limit or quota error from runner output.
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
    DEFAULT_AGENT_STARTUP_TIMEOUT = 300    # 5 minutes without first output = stuck
    PREFLIGHT_TIMEOUT_SECONDS = 10
    CHANGE_DETECTION_MAX_ATTEMPTS = 3
    CHANGE_DETECTION_RETRY_BACKOFF = 0.25
    POST_RUN_BOOKKEEPING_ERROR_TYPE = "PostRunBookkeepingFailed"

    def self.runner_order(agent_type:, fallback_enabled:, fallback_runners:)
      return [ agent_type ].select { |p| container_executable?(p) } unless fallback_enabled

      canonical = AGENT_TYPE_TO_RUNNER.fetch(agent_type, agent_type)
      runners = [ agent_type ]
      seen = Set.new([ canonical ])

      Array(fallback_runners).each do |fallback|
        fallback_canonical = AGENT_TYPE_TO_RUNNER.fetch(fallback, fallback)
        next if seen.include?(fallback_canonical)

        seen << fallback_canonical
        runners << fallback
      end

      runners.select { |p| container_executable?(p) }
    end

    def self.runner_attempt_count(agent_type:, fallback_enabled:, fallback_runners:)
      runner_order(
        agent_type: agent_type,
        fallback_enabled: fallback_enabled,
        fallback_runners: fallback_runners
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
        runners = build_runner_order(agent_run, user_settings)
        runner_states = load_runner_state_cache(user_settings.user, runners)

        pre_agent_sha = nil
        last_error = nil
        last_attempted_label = nil
        timeout_error = nil
        rate_limit_reset_at = nil
        skipped_rate_limited_count = 0

        max_execution_seconds = resolve_max_execution_seconds(agent_run, user_settings)

        index = 0
        while index < runners.length
          runner_candidate = runners[index]
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

          # Skip routing keys whose runner entry has been deleted — attempting
          # execution would fail with "Unsupported runner" and leak internal
          # identifiers in user-visible error messages.
          if Runner.routing_key?(runner_candidate) && runner_entry_for(runner_candidate, user_settings.user).nil?
            agent_run.record_runner_attempt("Deleted runner entry", success: false, error_type: "unavailable")
            index += 1
            next
          end

          runner = runner_command_key(runner_candidate, agent_run, user_settings.user)
          attempt_label = runner_attempt_label(runner_candidate, agent_run, user_settings.user)
          runner_state_name = state_key_for(runner_candidate, runner, user_settings.user)
          heartbeat("runner_attempt", runner, index)

          # Skip unavailable runners, tracking rate-limited skips separately
          if runner_unavailable?(user_settings, runner_state_name, runner_states)
            state = runner_states[runner_state_name]
            error_type = state&.rate_limited? ? "rate_limited" : "unavailable"
            skipped_rate_limited_count += 1 if error_type == "rate_limited"
            error_message = if error_type == "rate_limited" && state&.rate_limited_until.present?
              "Skipped due to cached rate limit until #{state.rate_limited_until.iso8601}"
            elsif error_type == "unavailable" && state&.circuit_open?
              "Skipped because runner circuit is open"
            end
            agent_run.record_runner_attempt(
              attempt_label,
              success: false,
              error_type: error_type,
              error_message: error_message
            )
            index += 1
            next
          end

          # Log runner switch when we have a previous actually-attempted runner.
          # Use attempt_label (per-entry identifier) so entries sharing the same
          # command key (e.g. two OpenCode API-key entries) are distinguishable.
          if last_attempted_label
            agent_run.log_runner_switch!(last_attempted_label, attempt_label, last_error || "fallback")
          end

          begin
            last_attempted_label = attempt_label
            attempt_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            runner_result = run_agent_with_runner(agent_run, runner_candidate, prompt, user_settings)
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            pre_agent_sha = runner_result.fetch(:pre_agent_sha)

            # Success - heartbeat and record final runner
            heartbeat("runner_completed", runner)
            record_runner_success(user_settings, runner_state_name, runner_states)
            agent_run.record_runner_attempt(attempt_label, success: true, duration_seconds: attempt_duration)
            # Persist the routing key so multiple entries sharing the same
            # runner_key (e.g. several OpenCode API-key entries with
            # different models) remain distinguishable in UI and retry logic.
            agent_run.update!(final_runner: attempt_label)

            # Skip git post-processing for goals that don't clone a repo.
            # These runs only interact via the GitHub API proxy — no git repo exists.
            #
            # Keep heartbeats flowing during post-run bookkeeping too. By the
            # time we reach this block the provider may already have posted a PR
            # review/comment, so a long-running git operation here can otherwise
            # leave the AgentRun stuck in "running" until stale-run cleanup.
            #
            # Do not run infinite-loop detection here: the agent is no longer
            # producing output, so re-scanning the same stdout snapshots during
            # git bookkeeping can falsely classify a successful run as looping.
            bookkeeping_result = with_periodic_heartbeat("post_run_bookkeeping", provider) do
              # Evaluate pre-commit requirements against the working directory
              # before committing, so blocking failures prevent commits.
              if agent_run.repo_cloned?
                pre_commit_result = evaluate_pre_commit_requirements(agent_run)
                if pre_commit_result[:blocking]
                  agent_run.log!("system", "Blocked by failing pre-commit requirements",
                    metadata: { pre_commit_results: pre_commit_result[:results] })
                  next {
                    early_return: {
                      agent_run_id: agent_run_id,
                      success: false,
                      has_changes: check_for_changes(agent_run, pre_agent_sha),
                      output_present: provider_result.fetch(:output_present),
                      final_provider: attempt_label,
                      error: "pre_commit_requirements_failed"
                    }
                  }
                end

                commit_uncommitted_changes(agent_run)
              end

              { has_changes: agent_run.repo_cloned? ? check_for_changes(agent_run, pre_agent_sha) : false }
            end

            return bookkeeping_result[:early_return] if bookkeeping_result[:early_return]

            has_changes = bookkeeping_result.fetch(:has_changes)

            if !has_changes && !runner_result.fetch(:output_present)
              agent_run.log!("system", "Runner completed with no output and no changes")
            end

            return {
              agent_run_id: agent_run_id,
              success: true,
              has_changes: has_changes,
              output_present: runner_result.fetch(:output_present),
              review_threads_already_addressed: runner_result.fetch(:review_threads_already_addressed, false),
              final_runner: attempt_label
            }
          rescue RunnerRateLimitError => e
            last_error = "rate_limited"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            rate_limit_reset_at = [ rate_limit_reset_at, e.reset_at ].compact.min
            persist_rate_limit(user_settings, runner_state_name, runner_states, e.reset_at)
            agent_run.record_runner_attempt(
              attempt_label,
              success: false,
              error_type: "rate_limited",
              error_message: e.message,
              duration_seconds: attempt_duration
            )
            logger.info(message: "agent_execution.rate_limited", runner: runner, agent_run_id: agent_run.id, duration_seconds: attempt_duration)
            if container_unavailable_for_fallback?(agent_run)
              # Peek at rate-limit fallback candidates without consuming them so
              # insert_rate_limit_fallbacks! can still insert after recovery.
              remaining_after_rate_limit_insertion = runners[(index + 1)..].to_a +
                peek_rate_limit_fallback_candidates(runner_candidate, runner, runners)

              break unless recover_container_for_fallback!(
                agent_run: agent_run,
                runner: runner,
                error_type: "rate_limited",
                error_message: e.message,
                fallback_remaining: remaining_after_rate_limit_insertion
              )
            end
            insert_rate_limit_fallbacks!(
              runners: runners,
              index: index,
              runner_candidate: runner_candidate,
              runner: runner,
              agent_run: agent_run
            )
          rescue InfiniteLoopError => e
            last_error = "infinite_loop"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            if cancelled_by_cleanup?(agent_run)
              record_cleanup_cancelled_attempt(agent_run, attempt_label, runner, e)
              break
            end
            record_runner_failure(user_settings, runner_state_name, runner_states)
            agent_run.record_runner_attempt(
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
          rescue RunnerTimeoutError => e
            last_error = "timeout"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            timeout_error ||= e.message
            if cancelled_by_cleanup?(agent_run)
              record_cleanup_cancelled_attempt(agent_run, attempt_label, runner, e)
              break
            end
            record_runner_failure(user_settings, runner_state_name, runner_states)
            agent_run.record_runner_attempt(
              attempt_label,
              success: false,
              error_type: "timeout",
              error_message: e.message,
              duration_seconds: attempt_duration,
              diagnostics: e.diagnostics
            )
            logger.warn(message: "agent_execution.runner_timeout", runner: runner, agent_run_id: agent_run.id, error: e.message, duration_seconds: attempt_duration)
            if container_unavailable_for_fallback?(agent_run)
              # Peek without consuming so future rate-limit fallback insertion
              # is not affected by this timeout recovery check.
              remaining_after_rate_limit_insertion = runners[(index + 1)..].to_a +
                peek_rate_limit_fallback_candidates(runner_candidate, runner, runners)

              break unless recover_container_for_fallback!(
                agent_run: agent_run,
                runner: runner,
                error_type: "timeout",
                error_message: e.message,
                fallback_remaining: remaining_after_rate_limit_insertion
              )
            end
            # Fall through to next runner instead of breaking — per-runner
            # timeout should not fail the entire run when fallback runners
            # are available. Only break when max_execution_seconds is exceeded
            # (checked at the top of the loop).
          rescue RunnerAuthExpiredError => e
            last_error = "auth_expired"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            auth_runner = RunnerSupport.harness_runner_key_for(e.runner)
            agent_run.auth_expire!(error: e.message, runner_key: auth_runner)
            agent_run.record_runner_attempt(
              attempt_label,
              success: false,
              error_type: "auth_expired",
              error_message: e.message,
              duration_seconds: attempt_duration
            )
            logger.warn(message: "agent_execution.auth_expired", runner: runner, agent_run_id: agent_run.id, error: e.message, duration_seconds: attempt_duration)
            break
          rescue RunnerExecutionError => e
            last_error = "error"
            attempt_duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - attempt_started_at).round(1)
            if cancelled_by_cleanup?(agent_run)
              record_cleanup_cancelled_attempt(agent_run, attempt_label, runner, e)
              break
            end
            record_runner_failure(user_settings, runner_state_name, runner_states)
            agent_run.record_runner_attempt(
              attempt_label,
              success: false,
              error_type: "error",
              error_message: e.message,
              duration_seconds: attempt_duration
            )
            logger.warn(message: "agent_execution.runner_failed", runner: runner, agent_run_id: agent_run.id, error: e.message, duration_seconds: attempt_duration)

            if container_dead_after_exec_error?(agent_run, e)
              logger.error(
                message: "agent_execution.container_dead_breaking_runner_loop",
                agent_run_id: agent_run.id,
                container_id: agent_run.container_id,
                error: e.message
              )
              break
            end
          end

          index += 1
        end

        # When all runners were skipped due to cached rate-limit state (no
        # attempts made), compute the earliest reset time from runner states.
        all_skipped_rate_limited = runners.any? && skipped_rate_limited_count == runners.size
        if rate_limit_reset_at.nil? && all_skipped_rate_limited
          reset_candidates = runners.filter_map do |runner|
            state = runner_states[state_key_for(runner, runner_command_key(runner, agent_run, user_settings.user), user_settings.user)]
            state&.rate_limited_until
          end
          rate_limit_reset_at = reset_candidates.min if reset_candidates.any?
        end

        # If a guardrail (e.g., cost budget enforcement from TokenUsageTracker)
        # paused the run during execution, preserve the paused state instead of
        # overwriting it with a terminal status.
        agent_run.reload
        return paused_result(agent_run_id) if agent_run.paused?

        # All runners exhausted. Timeout takes precedence over rate_limited
        # because it indicates an actual execution attempt that should trigger
        # ProcessRunQueueJob to re-schedule work.
        if timeout_error.present?
          timed_out = !agent_run.finished? && agent_run.timeout!(error: timeout_error)
          Notifications::Rules::ZeroIterationTimeout.call(scope: agent_run) if timed_out
          # Skip queue processing when cleanup killed the run — the timeout
          # was not a real runner issue, so there is nothing to re-schedule.
          # (agent_run was reloaded above, so the model method sees current state)
          ProcessRunQueueJob.perform_later if timed_out && !agent_run.cancelled_by_cleanup?
        elsif !agent_run.finished? && (last_error == "rate_limited" || all_skipped_rate_limited)
          runner_list = runners.any? ? runner_attempt_labels(runners, agent_run, user_settings.user).join(", ") : "none"
          agent_run.rate_limit!(
            error: "All runners rate limited: #{runner_list}",
            reset_at: rate_limit_reset_at
          )
        elsif !agent_run.finished?
          runner_list = runners.any? ? runner_attempt_labels(runners, agent_run, user_settings.user).join(", ") : "none"
          agent_run.fail!(error: "All runners exhausted: #{runner_list}")
        end
        raise Temporalio::Error::ApplicationError.new(
          "All runners exhausted",
          type: "AllRunnersExhausted",
          non_retryable: true
        )
      end
    end

    # Custom error classes for runner-specific failures
    class RunnerRateLimitError < StandardError
      attr_reader :reset_at

      def initialize(message, reset_at: nil)
        super(message)
        @reset_at = reset_at
      end
    end

    class RunnerAuthExpiredError < StandardError
      attr_reader :runner

      def initialize(message, runner:)
        super(message)
        @runner = runner
      end
    end

    class RunnerExecutionError < StandardError; end
    class RunnerTimeoutError < StandardError
      attr_reader :timeout_type, :diagnostics

      def initialize(message, timeout_type: nil, diagnostics: {})
        @timeout_type = timeout_type
        @diagnostics = diagnostics
        super(message)
      end
    end
    class InfiniteLoopError < StandardError; end
    CommandContext = Struct.new(:runner_candidate, :runner, :user, keyword_init: true)

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

    # Resolves max_execution_seconds with user setting taking precedence
    # over the project-level value. This allows users to override the
    # project default (eventually deprecating the project-level setting).
    def resolve_max_execution_seconds(agent_run, user_settings)
      user_settings&.max_execution_seconds || agent_run.project.max_execution_seconds
    end

    def effective_startup_timeout(heartbeat:, effective_idle_timeout:, effective_timeout:)
      startup_base =
        heartbeat.idle_timeout_for(effective_idle_timeout) ||
        effective_idle_timeout ||
        DEFAULT_AGENT_STARTUP_TIMEOUT

      [ startup_base, effective_timeout ].compact.min
    end

    # Builds the ordered list of runners to attempt.
    # Uses fallback runners if enabled, otherwise just the agent's type.
    # Rate-limit fallback runners are tracked separately (via
    # @rate_limit_fallbacks) and handled during execution; they do not
    # modify the runner order returned by this method.
    #
    # @return [Array<String>] Runner names in priority order
    def build_runner_order(agent_run, user_settings)
      if agent_run.runner
        runners = [ agent_run.runner.routing_key ]
        if user_settings.fallback_enabled
          runners.concat(user_settings.fallback_priority_for(primary_runner: agent_run.runner.routing_key, identifiers: true))
        end
      else
        runners =
          if user_settings.fallback_enabled
            fallback_runners = user_settings.fallback_priority_for(
              primary_runner: canonical_runner(agent_run.agent_type),
              identifiers: true
            )
            deduplicate_runner_candidates(
              primary_runner: agent_run.agent_type,
              fallback_runners: fallback_runners,
              user: user_settings.user
            )
          else
            [ agent_run.agent_type ].select { |runner| self.class.container_executable?(runner) }
          end
      end

      runners = runners.select do |runner_candidate|
        self.class.container_executable?(runner_command_key(runner_candidate, agent_run, user_settings.user))
      end
      if runners.empty? && fallback_to_default_runner?(agent_run)
        runners = default_runner_candidates(agent_run, user_settings)
      end

      @rate_limit_fallbacks = load_rate_limit_fallbacks(user_settings.user)
      @inserted_rate_limit_fallbacks = Set.new

      runners
    end

    # Checks if a runner is currently unavailable (rate limited or circuit open).
    #
    # @return [Boolean] true if runner should be skipped
    def runner_unavailable?(user_settings, runner_state_name, runner_states)
      state = runner_states.fetch(runner_state_name) do
        runner_states[runner_state_name] = user_settings.user.runner_states.find_by(runner_name: runner_state_name)
      end
      return false unless state

      # Check for circuit recovery before deciding
      state.check_circuit_recovery!(timeout: user_settings.circuit_breaker_timeout_seconds)

      state.unavailable?
    end

    # Records a rate limit for a runner.
    def persist_rate_limit(user_settings, runner_state_name, runner_states, reset_at = nil)
      state = runner_state_for(user_settings, runner_state_name, runner_states)
      state.mark_rate_limited!(reset_at: reset_at)
    end

    # Records a successful runner execution.
    def record_runner_success(user_settings, runner_state_name, runner_states = nil)
      state = runner_states ? runner_states[runner_state_name] : user_settings.user.runner_states.find_by(runner_name: runner_state_name)
      state&.record_success!
    end

    # Records a failed runner execution.
    def record_runner_failure(user_settings, runner_state_name, runner_states)
      state = runner_state_for(user_settings, runner_state_name, runner_states)
      state.record_failure!(threshold: user_settings.circuit_breaker_failure_threshold)
    end

    # True when the agent run we're executing has already been force-timed-out
    # by external cleanup (e.g. `dev:cleanup` or `StaleRunDetectorJob` killed
    # our container). In that case the failure we just rescued was caused by
    # cleanup, not by the runner, so we must not penalize the circuit breaker.
    def cancelled_by_cleanup?(agent_run)
      agent_run.reload
      agent_run.cancelled_by_cleanup?
    rescue ActiveRecord::RecordNotFound
      false
    end

    # Mirror of the failed-attempt bookkeeping for externally-cancelled runs:
    # records the attempt with a distinct error_type so the UI can show what
    # happened, but skips both record_runner_failure and the standard warn
    # log (which would imply a real runner problem).
    def record_cleanup_cancelled_attempt(agent_run, attempt_label, runner, error)
      agent_run.record_runner_attempt(attempt_label, success: false, error_type: "cancelled_by_cleanup")
      logger.info(
        message: "agent_execution.cancelled_by_cleanup",
        runner: runner,
        agent_run_id: agent_run.id,
        error: error.message
      )
    end

    # Returns the canonical settings-level runner name for a given agent type.
    def canonical_runner(runner)
      AGENT_TYPE_TO_RUNNER.fetch(runner, runner)
    end

    def default_runner_candidates(agent_run, user_settings)
      first_key = RunnerSupport.container_executable_runner_keys.first
      default_fallback = first_key ? RunnerSupport.agent_type_for(first_key) : "claude_code"

      candidates = [
        user_settings.default_runner_identifier_for_goal(agent_run.goal),
        default_fallback
      ].compact_blank

      seen = Set.new
      candidates.each_with_object([]) do |runner_candidate, runnable|
        runner = runner_command_key(runner_candidate, agent_run, user_settings.user)
        next unless self.class.container_executable?(runner)

        canonical = canonical_runner(runner)
        next if seen.include?(canonical)

        seen << canonical
        runnable << runner_candidate
      end
    end

    def fallback_to_default_runner?(agent_run)
      return true if agent_run.runner.present?

      runner_key = Runner.runner_key_for_agent_type(agent_run.agent_type)
      AgentRun::AGENT_TYPES.include?(agent_run.agent_type) &&
        RunnerSupport.supported_runner_key?(runner_key)
    end

    def runner_state_for(user_settings, runner_state_name, runner_states)
      runner_states[runner_state_name] ||= user_settings.runner_state_for(runner_state_name)
    end

    def load_runner_state_cache(user, runners)
      runner_state_names = runners.map { |runner| state_key_for(runner, runner_command_key(runner, nil, user), user) }.uniq
      user.runner_states.where(runner_name: runner_state_names).index_by(&:runner_name)
    end

    # Runs the agent with a specific runner.
    # Raises RunnerRateLimitError, RunnerTimeoutError, or RunnerExecutionError on failure.
    #
    # @return [Hash] The pre-agent SHA and whether output was present
    def run_agent_with_runner(agent_run, runner_candidate, prompt, user_settings)
      container_service = reconnect_container(agent_run)

      unless container_service.container_running?
        container_exit_info = container_exit_diagnostics(container_service)
        raise RunnerExecutionError,
          "Container #{agent_run.container_id} is not running. #{container_exit_info}"
      end

      runner = runner_command_key(runner_candidate, agent_run, user_settings.user)

      unless self.class.container_executable?(runner)
        raise RunnerExecutionError, "Unsupported runner: #{runner}"
      end

      # Assemble effective MCP servers from the run's provisioned state so
      # harness_execution_plan_for can pass them to agent-harness for
      # runner-specific translation. Stored as an instance variable so the
      # plan builder (which does not receive agent_run) can read it.
      @effective_mcp_servers = effective_mcp_servers_for(agent_run)
      validate_runner_mcp_support!(runner, @effective_mcp_servers)

      # Refresh the co-author trailer file before the agent runs so any
      # intermediate commits it creates via the commit-msg hook carry the
      # trailer for the runner actually producing them. Without this,
      # rate-limit fallback would leave the hook bound to the initial
      # runner's trailer for every subsequent commit in the run.
      if agent_run.repo_cloned?
        refresh_co_author_trailer(container_service, agent_run, runner_candidate, user_settings.user)
      end

      prompt = augment_prompt_for_goal(agent_run, prompt)
      command_context = CommandContext.new(
        runner_candidate: runner_candidate,
        runner: runner,
        user: user_settings.user
      )
      command = build_command(command_context, prompt)
      command_env = command_env_for(command_context, prompt)
      command_preparation = command_preparation_for(command_context, prompt)

      resolved_harness_provider = begin
        harness_provider_for(runner)
      rescue AgentHarness::ConfigurationError, KeyError
        nil
      end

      heartbeat = Containers::HeartbeatSetup.new(
        runner: runner,
        worktree_path: agent_run.worktree_path,
        host_heartbeat_path: container_service.heartbeat_host_path,
        harness_provider: resolved_harness_provider
      )
      if heartbeat.available?
        command_env = command_env.merge(heartbeat.env)
        command_preparation = merge_preparations(command_preparation, heartbeat.preparation)
      end

      raise RunnerExecutionError, "Agent run already finished with status #{agent_run.status}" if agent_run.finished?

      pre_agent_sha = capture_head_sha(container_service, agent_run)

      run_runner_preflight!(
        agent_run: agent_run,
        container_service: container_service,
        command_context: command_context,
        runner: runner,
        execution_env: command_env
      )

      # Only start! on first runner attempt.
      agent_run.start! unless agent_run.running?

      agent_run.log!("system", "Starting #{runner} agent in container")
      agent_run.log!("system", "Prompt: #{prompt.truncate(500)}")
      log_container_context(agent_run, runner)
      execution_started_at = Time.current

      effective_timeout = if agent_run.create_issue_goal? || agent_run.enhance_issue_goal? || agent_run.analyze_issue_goal?
        user_settings&.issue_goal_timeout_seconds || DEFAULT_ISSUE_GOAL_TIMEOUT
      else
        user_settings&.agent_timeout_seconds || agent_timeout
      end

      # Cap timeout by the resolved max execution time limit (user setting
      # overrides project default). Uses started_at to compute remaining
      # budget so the limit covers the full run, not just a single runner attempt.
      max_exec = resolve_max_execution_seconds(agent_run, user_settings)
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
      startup_timeout = effective_startup_timeout(
        heartbeat: heartbeat,
        effective_idle_timeout: effective_idle_timeout,
        effective_timeout: effective_timeout
      )

      # Periodic heartbeats during container execution complement the
      # checkpoint heartbeats at runner attempt boundaries (lines 106, 129).
      # Runner calls can run for many minutes, so without periodic
      # heartbeats the 120s heartbeat_timeout would fire mid-execution.
      result = with_periodic_heartbeat("executing", runner, agent_run: agent_run) do
        container_service.execute(
          command,
          timeout: effective_timeout,
          startup_timeout: startup_timeout,
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
        # Detect runner credit/quota errors that slip through as successful
        # exits. Some runners (e.g. OpenRouter) return a billing error as
        # the only stdout line with exit code 0. The agent never actually ran,
        # so treat this as a runner failure to trigger fallback/retry.
        combined_output = [ stdout, stderr ].compact.join("\n")
        sanitized_output = strip_prompt_echo(combined_output, prompt)
        if insufficient_credits_error?(sanitized_output)
          raise RunnerExecutionError,
            "Runner credit/quota error from #{runner}: #{sanitized_output.truncate(500)}"
        end

        if runner_model_not_found_error?(sanitized_output)
          raise RunnerExecutionError,
            "Runner model not found error from #{runner}: #{sanitized_output.truncate(500)}"
        end

        output_present = stdout.present? || stderr.present?
        track_harness_tokens(agent_run, runner_candidate, runner, user_settings.user, result, execution_started_at)
        agent_run.log!("system", "Agent execution succeeded with #{runner}")
        return {
          pre_agent_sha: pre_agent_sha,
          output_present: output_present,
          review_threads_already_addressed: review_threads_already_addressed?(stdout: stdout, stderr: stderr, prompt: prompt)
        }
      end

      output = (stderr.presence || stdout).to_s.strip
      rate_limit_output = strip_prompt_echo(output, prompt)

      if auth_expired_error?(runner, rate_limit_output)
        raise RunnerAuthExpiredError.new(output.truncate(500), runner: runner)
      end

      # Check if this is a rate limit error
      if rate_limit_error?(rate_limit_output)
        reset_at = rate_limit_reset_at(runner, rate_limit_output)
        raise RunnerRateLimitError.new("Rate limited by #{runner}", reset_at: reset_at)
      end

      # Other execution error
      raise RunnerExecutionError, "Agent exited with code #{result[:exit_code]}: #{output.truncate(500)}"
    rescue Containers::Provision::TimeoutError => e
      # execution_started_at is nil if the timeout fires before execution
      # begins (e.g. during start!/callbacks); recent_timeout_output
      # short-circuits on blank.
      timeout_output = recent_timeout_output(agent_run, since: execution_started_at, prompt: prompt)
      if timeout_rate_limit_error?(timeout_output)
        reset_at = rate_limit_reset_at(runner, timeout_output)
        raise RunnerRateLimitError.new("Rate limited by #{runner}", reset_at: reset_at)
      end

      timeout_type = case e
      when Containers::Provision::StartupTimeoutError then "startup"
      when Containers::Provision::IdleTimeoutError then "idle"
      else "wall_clock"
      end
      raise RunnerTimeoutError.new(
        "#{timeout_type}_timeout: #{e.message}",
        timeout_type: timeout_type,
        diagnostics: timeout_attempt_diagnostics(
          timeout_error: e,
          timeout_type: timeout_type,
          heartbeat: heartbeat,
          effective_timeout: effective_timeout,
          startup_timeout: startup_timeout,
          effective_idle_timeout: effective_idle_timeout
        )
      )
    rescue Containers::Provision::OutputAbortError => e
      # The container was stopped early because stderr matched a fatal
      # runner quota pattern (e.g. KiloCode "Free tier limit reached").
      # Classify as rate-limited so dashboards and retry logic see the
      # real root cause instead of a generic timeout.
      reset_at = rate_limit_reset_at(runner, e.matched_output.to_s)
      raise RunnerRateLimitError.new(
        "Rate limited by #{runner}: #{e.matched_output.to_s.truncate(200)}",
        reset_at: reset_at
      )
    rescue Containers::Provision::ExecutionError => e
      raise RunnerExecutionError, "Docker exec error: #{e.message}"
    end

    def run_runner_preflight!(agent_run:, container_service:, command_context:, runner:, execution_env:)
      # Run the runner-owned harness preflight (auth, CLI version,
      # OPENAI_BASE_URL reachability) when available — fails fast before
      # the smoke exec below.  The smoke exec always runs as a safety
      # net regardless of whether the harness supports preflight_check.
      #
      # Skip the harness preflight for subscription-auth runners: it
      # runs outside the container where OAuth credentials (auth.json,
      # .credentials.json) are unavailable.  The harness auth check only
      # understands API keys, so subscription auth always appears invalid.
      # The smoke-exec preflight below runs inside the container with the
      # correct environment and will catch real auth failures.
      runner_entry = runner_entry_for(command_context.runner_candidate, command_context.user)
      subscription_auth = runner_entry&.subscription? &&
        RunnerSupport.subscription_auth_unset_vars_for(runner_entry.runner_key).any?
      harness_provider = preflight_provider_instance(command_context)
      if harness_provider && !subscription_auth
        run_harness_preflight!(
          agent_run: agent_run,
          harness_provider: harness_provider,
          runner: runner,
          execution_env: execution_env
        )
      end

      prompt = runner_preflight_prompt_for(runner)
      command = build_command(command_context, prompt)
      env = command_env_for(command_context, prompt)
      preparation = command_preparation_for(command_context, prompt)

      result = container_service.execute(
        command,
        timeout: PREFLIGHT_TIMEOUT_SECONDS,
        idle_timeout: PREFLIGHT_TIMEOUT_SECONDS,
        env: env,
        preparation: preparation,
        abort_patterns: aggregated_abort_patterns
      )
      stdout = normalize_output_text(result[:stdout])
      stderr = normalize_output_text(result[:stderr])
      output = [ stderr.presence, stdout.presence ].compact.first.to_s.strip
      sanitized_output = strip_prompt_echo(output, prompt)

      if result.success?
        if insufficient_credits_error?(sanitized_output)
          raise_preflight_failure!(
            agent_run: agent_run,
            runner: runner,
            reason: "Runner credit/quota error: #{sanitized_output.truncate(500)}"
          )
        end

        if runner_model_not_found_error?(sanitized_output)
          raise_preflight_failure!(
            agent_run: agent_run,
            runner: runner,
            reason: "Runner model not found error: #{sanitized_output.truncate(500)}"
          )
        end

        return
      end

      if rate_limit_error?(sanitized_output)
        reset_at = rate_limit_reset_at(runner, sanitized_output)
        log_preflight_failure(agent_run: agent_run, runner: runner, reason: "Rate limited by #{runner} during preflight")
        raise RunnerRateLimitError.new("Rate limited by #{runner}", reset_at: reset_at)
      end

      reason = if sanitized_output.present?
        "Agent exited with code #{result[:exit_code]}: #{sanitized_output.truncate(500)}"
      else
        "No output before exit code #{result[:exit_code]}. Check proxy configuration, auth, and network policy."
      end
      raise_preflight_failure!(agent_run: agent_run, runner: runner, reason: reason)
    rescue Containers::Provision::TimeoutError => e
      reason = "Timed out after #{PREFLIGHT_TIMEOUT_SECONDS}s: #{e.message}. Check proxy configuration, auth, and network policy."
      raise_preflight_failure!(agent_run: agent_run, runner: runner, reason: reason)
    rescue Containers::Provision::OutputAbortError => e
      reset_at = rate_limit_reset_at(runner, e.matched_output.to_s)
      log_preflight_failure(agent_run: agent_run, runner: runner, reason: e.matched_output.to_s.truncate(200))
      raise RunnerRateLimitError.new(
        "Rate limited by #{runner}: #{e.matched_output.to_s.truncate(200)}",
        reset_at: reset_at
      )
    rescue Containers::Provision::ExecutionError => e
      raise_preflight_failure!(
        agent_run: agent_run,
        runner: runner,
        reason: "Docker exec error: #{e.message}"
      )
    end

    def run_harness_preflight!(agent_run:, harness_provider:, runner:, execution_env:)
      result = harness_provider.preflight_check(env: execution_env, timeout: PREFLIGHT_TIMEOUT_SECONDS)

      return if result[:healthy]

      reason = result[:reason] || "Preflight check failed"
      raise_preflight_failure!(agent_run: agent_run, runner: runner, reason: reason)
    rescue AgentHarness::ConfigurationError, KeyError
      # Runner config unavailable — skip harness preflight and let the
      # smoke execution catch any real issues.
      nil
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
    def log_container_context(agent_run, runner)
      logger.info(
        message: "agent_execution.container_context",
        agent_run_id: agent_run.id,
        runner: runner.to_s,
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

    def auth_expired_error?(runner, output)
      return false if output.blank?

      runner_key = RunnerSupport.runner_key_for_agent_type(runner)
      RunnerSupport.error_classification_patterns_for(runner_key, :auth_expired)
        .any? { |pattern| output.match?(pattern) }
    end

    QUOTA_ERROR_MAX_OUTPUT_LENGTH = 500

    # Detects runner-level credit/quota exhaustion errors surfaced as
    # agent output. Used in the successful-exit-code path to catch cases
    # where a runner (e.g. OpenRouter) returns a billing error as the
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

      RunnerSupport.aggregated_error_classification_patterns(:quota)
        .any? { |pattern| output.match?(pattern) }
    end

    MODEL_NOT_FOUND_MAX_OUTPUT_LENGTH = 1000

    MODEL_NOT_FOUND_PATTERNS = [
      /ProviderModelNotFoundError/i,
      /Error:\s*Model not found:/i
    ].freeze

    MODEL_NOT_FOUND_NOISE_LINE_PATTERNS = [
      %r{\A\s*at\s+.+\z},
      %r{\A\s*file://.+\z},
      %r{\A\s*/.+:\d+:\d+\)?\z},
      /\A\s*\^+\s*\z/
    ].freeze

    def runner_model_not_found_error?(output)
      return false if output.blank?

      signal = strip_model_not_found_noise(output)
      return false if signal.length > MODEL_NOT_FOUND_MAX_OUTPUT_LENGTH

      MODEL_NOT_FOUND_PATTERNS.any? { |pattern| signal.match?(pattern) }
    end

    def strip_model_not_found_noise(output)
      output.each_line.reject { |line| model_not_found_noise_line?(line) }.join
    end

    def model_not_found_noise_line?(line)
      normalized_line = line.to_s.strip
      return false if normalized_line.blank?

      MODEL_NOT_FOUND_NOISE_LINE_PATTERNS.any? { |pattern| normalized_line.match?(pattern) }
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

    def rate_limit_reset_at(runner_key, output)
      RunnerSupport.rate_limit_reset_at(harness_provider_for(runner_key), output)
    end

    def harness_provider_for(runner_key)
      app_runner_key = RunnerSupport.runner_key_for_agent_type(runner_key)
      harness_key = RunnerSupport.harness_runner_key_for(app_runner_key).to_sym
      AgentHarness.provider(harness_key)
    end

    def aggregated_abort_patterns
      RunnerSupport.aggregated_error_classification_patterns(:abort)
    end

    def track_harness_tokens(agent_run, runner_candidate, runner_key, user, result, execution_started_at)
      response =
        begin
          parse_harness_response(runner_candidate, runner_key, user, result, execution_started_at)
        rescue => e
          logger.warn(
            message: "agent_execution.token_usage_parse_failed",
            agent_run_id: agent_run.id,
            runner: runner_key.to_s,
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

    def parse_harness_response(runner_candidate, runner_key, user, result, execution_started_at)
      harness_provider = harness_response_provider(runner_candidate, runner_key, user)
      response = harness_provider.parse_container_output(
        stdout: result[:stdout],
        stderr: result[:stderr],
        exit_code: result[:exit_code],
        duration: harness_duration(execution_started_at)
      )
      apply_runtime_model(response, runner_candidate, user)
    end

    def harness_response_provider(runner_candidate, runner_key, user)
      app_runner_key = RunnerSupport.runner_key_for_agent_type(runner_key)
      harness_key = RunnerSupport.harness_runner_key_for(app_runner_key).to_sym
      klass = AgentHarness.provider_class(harness_key)
      config = harness_response_config(harness_key, runner_candidate, user)
      # Pass a no-op executor to satisfy runners whose initializer requires
      # one for execution. This instance is only used for parse_response, so
      # the executor is never invoked.
      klass.new(executor: NULL_EXECUTOR, config: config)
    end

    def preflight_provider_for(command_context)
      harness_response_provider(
        command_context.runner_candidate,
        command_context.runner,
        command_context.user
      )
    end

    # Returns an instantiated harness provider if it supports preflight_check,
    # or nil when config is unavailable.  Callers reuse the returned instance
    # to avoid double-instantiation overhead.
    def preflight_provider_instance(command_context)
      provider = preflight_provider_for(command_context)
      return nil unless provider.respond_to?(:preflight_check)
      return nil if provider.method(:preflight_check).owner == AgentHarness::Providers::Base

      provider
    rescue AgentHarness::ConfigurationError, KeyError
      nil
    end

    def runner_preflight_prompt_for(runner_key)
      harness_provider = harness_provider_for(runner_key)
      harness_provider.class.smoke_test_contract&.fetch(:prompt, nil).presence || "Reply with exactly OK."
    rescue AgentHarness::ConfigurationError, KeyError
      "Reply with exactly OK."
    end

    def log_preflight_failure(agent_run:, runner:, reason:)
      logger.warn(
        message: "agent_execution.preflight_failed",
        runner: runner,
        agent_run_id: agent_run.id,
        reason: reason
      )
    end

    def raise_preflight_failure!(agent_run:, runner:, reason:)
      log_preflight_failure(agent_run: agent_run, runner: runner, reason: reason)
      raise RunnerExecutionError, "Preflight check failed: #{reason}"
    end

    def harness_response_config(harness_key, runner_candidate, user)
      config = AgentHarness.build_config(harness_key)
      config.externally_sandboxed = true
      config.model = runner_runtime_model(runner_candidate, user)
      config
    end

    def apply_runtime_model(response, runner_candidate, user)
      model = runner_runtime_model(runner_candidate, user)
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

    def runner_runtime_model(runner_candidate, user)
      runner_entry_for(runner_candidate, user)&.agent_harness_provider_runtime&.model
    end

    def harness_duration(execution_started_at)
      return 0.0 unless execution_started_at

      Time.current - execution_started_at
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
      runner_entry = runner_entry_for(command_context.runner_candidate, command_context.user)

      if runner_entry&.agent_harness_runtime?
        harness_runtime_command(runner_entry, prompt)
      elsif runner_entry&.requires_direct_outbound?
        plan = harness_execution_plan_for(command_context.runner, prompt, runner_entry: runner_entry)
        runner_entry.direct_outbound_exec_command(command_prefix: plan.command[0..-2], prompt: prompt)
      elsif runner_entry&.api_key?
        plan = harness_execution_plan_for(command_context.runner, prompt)
        api_key_auth_command(runner_entry, plan.command[0..-2], prompt)
      elsif RunnerSupport.subscription_auth_unset_vars_for(command_context.runner).any?
        plan = harness_execution_plan_for(command_context.runner, prompt)
        subscription_auth_command(command_context.runner, plan.command[0..-2], prompt)
      else
        plan = harness_execution_plan_for(command_context.runner, prompt)
        plan.command
      end
    end

    # Builds a harness execution plan for a runner identified by its
    # app-level key. Delegates command construction to agent-harness so
    # runner CLI flag semantics are owned upstream.
    #
    # The plan is cached per (runner_key, prompt, harness_runtime?,
    # effective_mcp_servers) tuple so that multiple branches within
    # build_command can share the same capture without re-running the
    # harness provider. The boolean discriminator ensures calls with
    # and without a runner_entry that has an
    # agent_harness_provider_runtime are never conflated. The MCP
    # servers are included so that a later execution on the same
    # activity instance with a different MCP setup does not reuse a
    # stale plan.
    def harness_execution_plan_for(runner_key, prompt, runner_entry: nil)
      @harness_plan_cache ||= {}
      cache_key = [ runner_key, prompt, runner_entry&.agent_harness_provider_runtime.present?, @effective_mcp_servers ]
      return @harness_plan_cache[cache_key] if @harness_plan_cache.key?(cache_key)

      options = { dangerous_mode: true }
      options[:mcp_servers] = @effective_mcp_servers if @effective_mcp_servers&.any?

      @harness_plan_cache[cache_key] = if runner_entry&.agent_harness_provider_runtime
        Runners::HarnessExecutionPlan.call(
          provider: runner_entry,
          prompt: prompt,
          options: options
        )
      else
        Runners::HarnessExecutionPlan.for_runner_key(
          runner_key: RunnerSupport.runner_key_for_agent_type(runner_key),
          prompt: prompt,
          options: options
        )
      end
    end

    def command_env_for(command_context, prompt)
      runner_entry = runner_entry_for(command_context.runner_candidate, command_context.user)
      return direct_outbound_execution_plan(runner_entry, prompt).env if runner_entry&.agent_harness_runtime?
      return {} unless runner_entry

      env = {}
      env.merge!(runner_entry.direct_outbound_exec_env) if runner_entry.requires_direct_outbound?
      env.merge!(api_key_command_env(runner_entry)) if runner_entry.api_key?
      env
    end

    def command_preparation_for(command_context, prompt)
      runner_entry = runner_entry_for(command_context.runner_candidate, command_context.user)
      return nil unless runner_entry&.agent_harness_runtime?

      direct_outbound_execution_plan(runner_entry, prompt).preparation
    end

    # Assembles the effective MCP server list from the agent run's
    # provisioned servers into the format expected by agent-harness
    # (array of Hashes with :name, :transport, :command/:url, etc.).
    #
    # Returns an empty array when no MCP servers are configured.
    def effective_mcp_servers_for(agent_run)
      provisioned = agent_run.mcp_provisioned_servers
      return [] if provisioned.blank?

      servers = []
      Array(provisioned["stdio_servers"]).each do |server|
        servers << server.symbolize_keys.slice(:name, :transport, :command, :args, :env)
      end
      Array(provisioned["url_servers"]).each do |server|
        servers << server.symbolize_keys.slice(:name, :transport, :url)
      end
      servers
    end

    # Validates that the runner supports MCP before attempting execution.
    # Raises RunnerExecutionError with a clear message when a run has MCP
    # servers but the selected runner does not support them, allowing the
    # fallback loop to try the next runner.
    def validate_runner_mcp_support!(runner_key, mcp_servers)
      return if mcp_servers.blank?

      harness_provider = begin
        harness_provider_for(runner_key)
      rescue AgentHarness::ConfigurationError, KeyError
        raise RunnerExecutionError,
          "Runner #{runner_key} is not recognized and cannot be validated for MCP support"
      end

      unless harness_provider.supports_mcp?
        raise RunnerExecutionError,
          "Runner #{runner_key} does not support MCP servers. " \
          "Select a runner with MCP capability or remove MCP servers from this project."
      end
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

    # Builds an execution plan for runners that use the agent-harness
    # runtime directly (e.g. opencode, copilot). MCP servers are
    # intentionally NOT propagated here because none of the runners
    # that route through this path currently support MCP — see
    # validate_runner_mcp_support! which rejects them earlier. If a
    # runner gains MCP support in the future, this method (and its
    # cache key) must be updated to include @effective_mcp_servers,
    # mirroring harness_execution_plan_for.
    def direct_outbound_execution_plan(runner_entry, prompt)
      @direct_outbound_execution_plan_cache ||= {}
      cache_key = [ runner_entry.id, prompt ]
      return @direct_outbound_execution_plan_cache[cache_key] if @direct_outbound_execution_plan_cache.key?(cache_key)

      @direct_outbound_execution_plan_cache[cache_key] = Runners::HarnessExecutionPlan.call(
        provider: runner_entry,
        prompt: prompt,
        options: { dangerous_mode: true }
      )
    end

    def runner_command_key(runner_candidate, agent_run, user = nil)
      runner_entry = runner_entry_for(runner_candidate, user)
      return runner_candidate unless runner_entry
      return "claude_code" if agent_run&.runner_id == runner_entry.id && runner_entry.runner_key == "claude" && agent_run.agent_type == "claude_code"

      runner_entry.runner_key
    end

    def state_key_for(runner_candidate, runner, user = nil)
      runner_entry = runner_entry_for(runner_candidate, user)
      return runner_entry.routing_key if runner_entry&.api_key?
      return runner_entry.runner_key if runner_entry

      canonical_runner(runner)
    end

    def runner_entry_for(runner_candidate, user)
      return runner_candidate if runner_candidate.is_a?(Runner)
      return nil unless user
      return nil unless Runner.routing_key?(runner_candidate)

      @runner_entry_cache ||= {}
      cache_key = [ user.id, runner_candidate ]
      return @runner_entry_cache[cache_key] if @runner_entry_cache.key?(cache_key)

      @runner_entry_cache[cache_key] = Runner.for_identifier(user, runner_candidate)
    end

    def deduplicate_runner_candidates(primary_runner:, fallback_runners:, user:)
      runners = [ primary_runner ]
      seen = Set.new([ canonical_runner_candidate(primary_runner, user) ])

      Array(fallback_runners).each do |runner_candidate|
        canonical_candidate = canonical_runner_candidate(runner_candidate, user)
        next if seen.include?(canonical_candidate)

        seen << canonical_candidate
        runners << runner_candidate
      end

      runners.select do |runner_candidate|
        self.class.container_executable?(runner_command_key(runner_candidate, nil, user))
      end
    end

    def canonical_runner_candidate(runner_candidate, user)
      runner_entry = runner_entry_for(runner_candidate, user)
      return runner_entry.runner_key if runner_entry

      canonical_runner(runner_candidate)
    end

    def load_rate_limit_fallbacks(user)
      return {} unless user
      return {} if user.new_record?

      executable_keys = RunnerSupport.container_executable_runner_keys

      user.runners.api_key.rate_limit_fallback.for_fallback
        .where(runner_key: executable_keys)
        .ordered
        .group_by(&:runner_key)
        .transform_values { |entries| entries.map(&:routing_key) }
    end

    def insert_rate_limit_fallbacks!(runners:, index:, runner_candidate:, runner:, agent_run:)
      fallback_candidates = rate_limit_fallback_candidates_for(runner_candidate, runner, runners)
      return if fallback_candidates.empty?

      logger.info(
        message: "agent_execution.rate_limit_fallback_available",
        runner: canonical_runner(runner),
        agent_run_id: agent_run.id,
        fallback_runners: fallback_candidates
      )

      runners.insert(index + 1, *fallback_candidates)
    end

    def rate_limit_fallback_candidates_for(runner_candidate, runner, runners)
      candidates = peek_rate_limit_fallback_candidates(runner_candidate, runner, runners)
      @inserted_rate_limit_fallbacks.merge(candidates)
      candidates
    end

    # Returns eligible rate-limit fallback candidates without marking them as
    # inserted. Use this when you need to check whether fallbacks exist (e.g.,
    # for container recovery decisions) without consuming them.
    def peek_rate_limit_fallback_candidates(runner_candidate, runner, runners)
      @inserted_rate_limit_fallbacks ||= Set.new

      canonical_key = canonical_runner(runner)
      configured = Array(@rate_limit_fallbacks&.fetch(canonical_key, []))
      return [] if configured.empty?

      already_scheduled = runners.to_set
      current_runner = runner_candidate.to_s

      configured.reject do |candidate|
        candidate == current_runner ||
          @inserted_rate_limit_fallbacks.include?(candidate) ||
          already_scheduled.include?(candidate)
      end
    end

    def simulated_runner_attempt_count(agent_run, runners, user)
      @rate_limit_fallbacks = load_rate_limit_fallbacks(user)
      @inserted_rate_limit_fallbacks = Set.new
      simulated_runners = runners.dup

      index = 0
      while index < simulated_runners.length
        runner_candidate = simulated_runners[index]
        runner = runner_command_key(runner_candidate, agent_run, user)
        fallback_candidates = rate_limit_fallback_candidates_for(runner_candidate, runner, simulated_runners)
        simulated_runners.insert(index + 1, *fallback_candidates) if fallback_candidates.any?
        index += 1
      end

      simulated_runners.size
    end

    # Returns a per-entry identifier suitable for persisting in
    # runners_attempted and final_runner. Uses the routing key for
    # API-key-backed entries so that multiple entries sharing the same
    # runner_key remain distinguishable; uses runner_key for
    # subscription entries so the value stays compatible with
    # matches_identifier?, effective_runner_sql, and dashboard
    # aggregations (which group by runner key, not agent_type).
    def runner_attempt_label(runner_candidate, agent_run, user)
      runner_entry = runner_entry_for(runner_candidate, user)
      return runner_entry.routing_key if runner_entry&.api_key?
      return runner_entry.runner_key if runner_entry
      runner_command_key(runner_candidate, agent_run, user)
    end

    def runner_attempt_labels(runners, agent_run, user)
      runners.map do |runner_candidate|
        runner_entry = runner_entry_for(runner_candidate, user)
        if runner_entry&.display_name
          runner_entry.display_name
        elsif Runner.routing_key?(runner_candidate)
          "Deleted runner entry"
        else
          runner_command_key(runner_candidate, agent_run, user)
        end
      end
    end

    class << self
      def runner_attempt_count_for_run(agent_run:, user_settings:)
        return 1 unless user_settings

        activity = new
        runners = activity.send(:build_runner_order, agent_run, user_settings)
        count = activity.send(:simulated_runner_attempt_count, agent_run, runners, user_settings.user)

        [ count, 1 ].max
      end
    end

    # Wraps a runner command so that, when subscription auth is active,
    # proxy-related env vars are unset and the CLI talks directly to the
    # runner. The prompt is passed as a positional parameter ($1) to
    # preserve multi-line content from augment_prompt_for_goal. The
    # unset-var list is shared with Runners::TestAgent via
    # RunnerSupport.subscription_auth_unset_vars_for.
    def subscription_auth_command(runner, command_prefix, prompt)
      base = command_prefix.shelljoin
      env_flag = "PAID_#{runner.upcase}_SUBSCRIPTION_AUTH"
      unset_flags = subscription_auth_unset_vars_for(runner)
      if runner == "copilot"
        unset_flags = unset_flags.reject { |var| var == "COPILOT_GITHUB_TOKEN" }
      end
      unset_str = unset_flags.map { |var| "-u #{var}" }.join(" ")

      script = "if [ \"$#{env_flag}\" = \"1\" ]; then env #{unset_str} #{base} \"$1\"; else #{base} \"$1\"; fi"
      [ "sh", "-c", script, "--", prompt ]
    end

    def api_key_auth_command(runner_entry, command_prefix, prompt)
      base = command_prefix.shelljoin
      env_assignments = api_key_env_var_names_for(runner_entry)
        .map { |var| %(#{var}="paid-run:$AGENT_RUN_ID:$PROXY_TOKEN") }
        .join(" ")
      header_assignments = api_key_proxy_header_assignments_for(runner_entry)
        .join(" ")

      script = "env #{header_assignments} #{env_assignments} #{base} \"$1\""
      [ "sh", "-c", script, "--", prompt ]
    end

    def api_key_command_env(runner_entry)
      { "PAID_PROVIDER_ID" => runner_entry.id.to_s }
    end

    def api_key_env_var_names_for(runner_entry)
      harness_provider_for(runner_entry.runner_key).api_key_env_var_names
    end

    def api_key_proxy_header_assignments_for(runner_entry)
      case runner_entry.runner_key
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

    def subscription_auth_unset_vars_for(runner)
      RunnerSupport.subscription_auth_unset_vars_for(runner)
    end

    # Wraps the harness execution plan command with `env -u` to strip
    # proxy-specific headers inherited from container startup so they
    # are not forwarded to the real runner API.
    def harness_runtime_command(runner_entry, prompt)
      plan = direct_outbound_execution_plan(runner_entry, prompt)
      unset_vars = RunnerSupport.harness_runtime_unset_vars_for(runner_entry.runner_key)
      RunnerSupport.command_with_unset_env(plan.command, unset_vars)
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

    def recover_container_for_fallback!(agent_run:, runner:, error_type:, error_message:, fallback_remaining:)
      if Array(fallback_remaining).blank?
        logger.error(
          message: "agent_execution.container_unavailable_breaking_runner_loop",
          agent_run_id: agent_run.id,
          container_id: agent_run.container_id,
          error: error_message,
          error_type: error_type,
          reason: "no_fallback_remaining"
        )
        return false
      end

      reprovision_container_for_fallback!(agent_run)
        logger.info(
        message: "agent_execution.container_reprovisioned_for_fallback",
        agent_run_id: agent_run.id,
        runner: runner,
        next_runners: Array(fallback_remaining).take(3)
      )
      true
    rescue StandardError => e
      logger.error(
        message: "agent_execution.container_unavailable_breaking_runner_loop",
        agent_run_id: agent_run.id,
        container_id: agent_run.container_id,
        error: error_message,
        error_type: error_type,
        reprovision_error: e.message
      )
      false
    end

    def container_dead_after_exec_error?(agent_run, error)
      return false unless error.message.match?(/container.*is not running/i)
      return false if agent_run.container_id.blank?

      container_service = reconnect_container(agent_run) rescue nil
      return false unless container_service

      !container_service.container_running?
    end

    def container_unavailable_for_fallback?(agent_run)
      agent_run.reload
      return true if agent_run.container_id.blank?

      container_service = reconnect_container(agent_run)

      !container_service.container_running?
    rescue StandardError => e
      return true if e.is_a?(ActiveRecord::RecordNotFound)
      return true if e.is_a?(Temporalio::Error::ApplicationError) && e.type == "ContainerNotProvisioned"
      return true if error_or_cause_matches?(e, Containers::Provision::ProvisionError) { |candidate|
        candidate.message.match?(/\AContainer .* not found\z/)
      }
      return false if reconnect_failure?(e)

      false
    end

    def reprovision_container_for_fallback!(agent_run)
      agent_run.ensure_proxy_token!
      agent_run.provision_container
      return unless agent_run.repo_cloned?

      container_service = reconnect_container(agent_run)
      git_ops = Containers::GitOperations.new(container_service: container_service, agent_run: agent_run)
      restore_repo_for_fallback!(git_ops, agent_run)
      git_ops.install_artifact_excludes
      install_quality_hooks_for_fallback(git_ops, agent_run)
      git_ops.install_co_author_hook
    end

    def restore_repo_for_fallback!(git_ops, agent_run)
      branch_name = agent_run.branch_name
      raise RunnerExecutionError, "Cannot restore repo without branch name" if branch_name.blank?

      git_ops.clone_and_restore_branch(
        branch_name: branch_name,
        base_commit_sha: agent_run.base_commit_sha,
        pull_request_number: agent_run.source_pull_request_number
      )
    end

    def install_quality_hooks_for_fallback(git_ops, agent_run)
      # Delegate to the shared concern method to avoid duplication
      install_quality_hooks(git_ops, agent_run)
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

    def timeout_attempt_diagnostics(timeout_error:, timeout_type:, heartbeat:, effective_timeout:, startup_timeout:, effective_idle_timeout:)
      runner_idle_timeout = heartbeat&.idle_timeout_for(effective_idle_timeout)
      diagnostics = timeout_error.diagnostics.dup
      diagnostics["output_received"] = timeout_type != "startup" if !diagnostics.key?("output_received") && timeout_type.present?

      diagnostics.merge(
        "timeout_type" => timeout_type,
        "effective_timeout_seconds" => effective_timeout,
        "startup_timeout_seconds" => startup_timeout,
        "configured_idle_timeout_seconds" => effective_idle_timeout,
        "idle_timeout_seconds" => runner_idle_timeout || effective_idle_timeout,
        "heartbeat_supported" => heartbeat&.available? || false,
        "heartbeat_path_configured" => heartbeat&.heartbeat_path.present? || false
      ).compact
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

      {{decomposition_instructions}}
    AUGMENTED

    NO_DECOMPOSE_LABEL = "no-decompose"

    DECOMPOSITION_INSTRUCTIONS = <<~'INSTRUCTIONS'
      ## Feature Decomposition

      The feature request you are analyzing is large enough to benefit from decomposition
      into multiple smaller, focused issues. Instead of creating a single large issue
      through the GitHub proxy, output a structured decomposition plan as a JSON array
      wrapped in HTML comment markers.

      The decomposition plan should break the feature into small, focused sub-issues that
      each produce a single PR. Order them so foundational work (data model, migrations)
      comes before dependent work (services, controllers, views).

      Each sub-issue must declare its dependencies using zero-based indices into the plan array.

      Output format:

      <!-- multi-issue-plan-start -->
      [
        {"title": "Add data model for feature X", "body": "Create migrations and models...", "dependencies": []},
        {"title": "Implement service layer for X", "body": "Build service objects...", "dependencies": [0]},
        {"title": "Add API endpoints for X", "body": "Create controller actions...", "dependencies": [1]},
        {"title": "Build UI views for X", "body": "Add view components...", "dependencies": [2]}
      ]
      <!-- multi-issue-plan-end -->

      If you are decomposing the work, do NOT create any GitHub issue directly.
      The platform will create the issues from the plan and automatically update the
      current source issue as the parent tracking issue with a task list of all
      created sub-issues.

      If a different existing issue should be the parent tracker instead, include:

      <!-- parent-issue: EXISTING_ISSUE_NUMBER -->

      before the plan. Otherwise the source issue is used. Each task's `dependencies`
      array contains indices of tasks that must be completed first.

      Rules:
      - Each sub-issue should be scoped to a single focused PR
      - Dependencies must form a valid DAG (no cycles)
      - Include clear acceptance criteria in each sub-issue body
      - Maximum 20 sub-issues
      - Use only the `dependencies` array for dependency wiring; do not add `Depends on #N` lines inside task bodies
    INSTRUCTIONS

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

      decomposition = decomposition_instructions_for(agent_run)

      vars = {
        base_prompt: prompt,
        repo: validated_repo_name(agent_run),
        decomposition_instructions: decomposition
      }

      rendered = resolve_and_persist_goal_prompt(
        agent_run: agent_run,
        slug: ISSUE_GOAL_PROMPT_SLUG,
        variables: vars,
        fallback_template: FALLBACK_ISSUE_GOAL_PROMPT
      )

      maybe_assign_ab_test_variant(agent_run, ISSUE_GOAL_PROMPT_SLUG, rendered, vars)
    end

    def decomposition_instructions_for(agent_run)
      issue = agent_run.issue
      return "" unless issue&.body.present?
      return "" if issue.has_label?(NO_DECOMPOSE_LABEL)

      scope_result = ScopeAnalysis::Analyze.call(text: issue.body)
      return "" unless scope_result.should_decompose?

      logger.info(
        message: "agent_execution.decomposition_instructions_injected",
        agent_run_id: agent_run.id,
        confidence: scope_result.confidence,
        sub_components: scope_result.sub_components
      )

      DECOMPOSITION_INSTRUCTIONS
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

      rendered_variant = variant_version.render(vars)
      append_missing_issue_goal_runtime_instructions(rendered_variant, slug, vars)
    end

    # Older running A/B variants may predate runtime-only additions such as
    # decomposition instructions. Keep those runs aligned with the current
    # issue-goal contract by appending required guidance when the stored
    # variant template cannot render it itself.
    def append_missing_issue_goal_runtime_instructions(rendered, slug, vars)
      return rendered unless slug == ISSUE_GOAL_PROMPT_SLUG

      append_prompt_section(rendered, vars[:decomposition_instructions])
    end

    def append_prompt_section(rendered, addition)
      normalized_addition = addition.to_s.strip
      return rendered if normalized_addition.blank?
      return rendered if rendered.include?(normalized_addition)

      "#{rendered.rstrip}\n\n#{normalized_addition}"
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

    # Writes the given runner candidate's co-author trailer into the
    # container so the commit-msg hook uses it for subsequent intermediate
    # commits. When no runner record can be resolved from the candidate
    # (e.g. non-routing-key agent_type), the file is cleared so the hook
    # falls back to a no-op rather than silently using a stale trailer.
    def refresh_co_author_trailer(container_service, agent_run, runner_candidate, user)
      runner_record = resolve_runner_record_for_candidate(runner_candidate, user)
      Containers::GitOperations
        .new(container_service: container_service, agent_run: agent_run)
        .write_co_author_trailer(runner_record)
    end

    def resolve_runner_record_for_candidate(runner_candidate, user)
      runner_entry = runner_entry_for(runner_candidate, user)
      return runner_entry if runner_entry
      return nil unless user
      return nil if runner_candidate.blank?

      identifier = runner_candidate.to_s
      Runner.for_identifier(user, identifier) ||
        Runner.for_identifier(user, RunnerSupport.runner_key_for_agent_type(identifier))
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
