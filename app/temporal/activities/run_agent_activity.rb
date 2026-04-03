# frozen_string_literal: true

require "shellwords"

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    # Maps agent_type/provider to the CLI command used inside the container.
    # Each entry is an array of command parts; the prompt is appended as the last argument.
    #
    # NOTE: This hash defines command templates for all providers the system
    # knows how to run. Currently Claude CLI, Codex CLI, Cursor agent CLI,
    # Gemini CLI, Kilocode CLI, OpenCode CLI, GitHub Copilot CLI, and Aider CLI
    # are installed in the agent Docker container (docker/agent/Dockerfile).
    #
    # Copilot remains hardcoded here for now instead of delegating to
    # agent-harness because the installed Copilot CLI and the harness's
    # built-in GitHub Copilot provider are not yet aligned on binary name and
    # invocation shape. Paid installs `github-copilot-cli`, while
    # agent-harness 0.5.6 expects `copilot -p ...`.
    # Actual container execution is
    # gated by ProviderSupport::CONTAINER_EXECUTABLE_PROVIDER_KEYS — providers
    # not in that set are filtered out upstream (UserSetting, ProvidersController)
    # before reaching provider_order.
    AGENT_COMMANDS = {
      "claude_code" => %w[claude --print --output-format=text --dangerously-skip-permissions -p],
      "claude" => %w[claude --print --output-format=text --dangerously-skip-permissions -p],
      "codex" => %w[codex exec --dangerously-bypass-approvals-and-sandbox --],
      "gemini" => %w[gemini -y -p],
      "kilocode" => %w[kilo run --auto],
      "opencode" => %w[opencode run],
      "copilot" => %w[github-copilot-cli --message],
      "cursor" => %w[cursor-agent --message],
      "aider" => %w[aider --yes --no-auto-commits --message]
    }.freeze

    # Maps agent_type values to their canonical settings provider name.
    # Some agent types (e.g., "claude_code") share the same underlying provider as
    # a settings-level name ("claude"), so they should be deduplicated during fallback.
    AGENT_TYPE_TO_PROVIDER = {
      "claude_code" => "claude"
    }.freeze

    # Patterns that indicate a rate limit or quota error from provider output.
    RATE_LIMIT_PATTERNS = [
      /rate.?limit/i,
      /too many requests/i,
      /(?:\bHTTP[\/\s]*429\b|status[:\s]*429\b)/i,
      /quota exceeded/i,
      /exhausted.*capacity/i,
      /(?:server|system)\s+(?:at\s+)?capacity/i,
      /(?:server|api|service)\s+overloaded/i,
      /out of (?:extra )?usage/i,
      /usage limit/i
    ].freeze

    # Default timeouts used when per-user settings are unavailable.
    # Runtime code resolves per-user values via UserSetting.
    DEFAULT_ISSUE_GOAL_TIMEOUT = 600        # 10 minutes wall clock
    DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT = 120   # 2 minutes without output = stuck
    DEFAULT_REVIEW_GOAL_IDLE_TIMEOUT = 300  # 5 minutes without output = stuck

    def self.provider_order(agent_type:, fallback_enabled:, fallback_providers:)
      return [ agent_type ].select { |p| AGENT_COMMANDS.key?(p) } unless fallback_enabled

      canonical = AGENT_TYPE_TO_PROVIDER.fetch(agent_type, agent_type)
      providers = [ agent_type ]
      seen = Set.new([ canonical ])

      Array(fallback_providers).each do |fallback|
        fallback_canonical = AGENT_TYPE_TO_PROVIDER.fetch(fallback, fallback)
        next if seen.include?(fallback_canonical)

        seen << fallback_canonical
        providers << fallback
      end

      providers.select { |p| AGENT_COMMANDS.key?(p) }
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
        last_attempted_provider = nil
        last_attempted_label = nil
        timeout_error = nil
        rate_limit_reset_at = nil
        skipped_rate_limited_count = 0

        max_execution_seconds = agent_run.project.max_execution_seconds

        providers.each_with_index do |provider_candidate, index|
          # Check if the project's execution time limit has been exceeded
          if max_execution_seconds && agent_run.started_at && (Time.current - agent_run.started_at).to_i >= max_execution_seconds
            violation_result = Guardrails::ViolationHandler.call(
              agent_run: agent_run,
              violation_type: "time_limit",
              details: "Execution time limit of #{max_execution_seconds}s exceeded",
              metrics: { max_execution_seconds: max_execution_seconds, elapsed_seconds: (Time.current - agent_run.started_at).to_i }
            )
            unless violation_result.paused?
              timeout_error = "Execution time limit of #{max_execution_seconds}s exceeded"
            end
            break
          end

          # Skip routing keys whose provider entry has been deleted — attempting
          # execution would fail with "Unsupported provider" and leak internal
          # identifiers in user-visible error messages.
          if Provider.routing_key?(provider_candidate) && provider_entry_for(provider_candidate, user_settings.user).nil?
            agent_run.record_provider_attempt("Deleted provider entry", success: false, error_type: "unavailable")
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
            agent_run.record_provider_attempt(attempt_label, success: false, error_type: error_type)
            next
          end

          # Log provider switch when we have a previous actually-attempted provider.
          # Use attempt_label (per-entry identifier) so entries sharing the same
          # command key (e.g. two OpenCode API-key entries) are distinguishable.
          if last_attempted_label
            agent_run.log_provider_switch!(last_attempted_label, attempt_label, last_error || "fallback")
          end

          begin
            last_attempted_provider = provider
            last_attempted_label = attempt_label
            provider_result = run_agent_with_provider(agent_run, provider_candidate, prompt, user_settings)
            pre_agent_sha = provider_result.fetch(:pre_agent_sha)

            # Success - heartbeat and record final provider
            heartbeat("provider_completed", provider)
            record_provider_success(user_settings, provider_state_name, provider_states)
            agent_run.record_provider_attempt(attempt_label, success: true)
            # Persist the routing key so multiple entries sharing the same
            # provider_key (e.g. several OpenCode API-key entries with
            # different models) remain distinguishable in UI and retry logic.
            agent_run.update!(final_provider: attempt_label)

            # Evaluate pre-commit requirements against the working directory
            # before committing, so blocking failures prevent commits.
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
            has_changes = check_for_changes(agent_run, pre_agent_sha)

            if !has_changes && !provider_result.fetch(:output_present)
              agent_run.log!("system", "Provider completed with no output and no changes")
            end

            return {
              agent_run_id: agent_run_id,
              success: true,
              has_changes: has_changes,
              output_present: provider_result.fetch(:output_present),
              final_provider: attempt_label
            }
          rescue ProviderRateLimitError => e
            last_error = "rate_limited"
            rate_limit_reset_at = [ rate_limit_reset_at, e.reset_at ].compact.min
            persist_rate_limit(user_settings, provider_state_name, provider_states, e.reset_at)
            agent_run.record_provider_attempt(attempt_label, success: false, error_type: "rate_limited")
            logger.info(message: "agent_execution.rate_limited", provider: provider, agent_run_id: agent_run.id)

            # Rate-limit fallback execution is not yet implemented. #546
            # added the UI for configuring API-key-backed fallback entries;
            # actual execution requires injecting the selected API key into
            # the container environment and adding api_key variants to the
            # provider order. Tracked separately — only logging availability
            # for now; no switch counters or AgentRun mutation until the
            # fallback is actually executed.
            canonical_provider_key = canonical_provider(provider)
            if @rate_limit_fallback_keys&.include?(canonical_provider_key)
              logger.info(
                message: "agent_execution.rate_limit_fallback_available",
                provider: canonical_provider_key,
                agent_run_id: agent_run.id
              )
            end
          rescue InfiniteLoopError => e
            record_provider_failure(user_settings, provider_state_name, provider_states)
            agent_run.record_provider_attempt(attempt_label, success: false, error_type: "infinite_loop")
            last_error = "infinite_loop"
            logger.warn(message: "agent_execution.infinite_loop_detected", agent_run_id: agent_run.id, reason: e.message)

            result = Guardrails::ViolationHandler.call(
              agent_run: agent_run,
              violation_type: "loop_detected",
              details: e.message,
              metrics: { detection_reason: e.message }
            )
            unless result.paused?
              agent_run.fail!(error: "Infinite loop detected: #{e.message}") unless agent_run.finished?
            end

            raise Temporalio::Error::ApplicationError.new(
              "Infinite loop detected: #{e.message}",
              type: "InfiniteLoopDetected",
              non_retryable: true
            )
          rescue ProviderTimeoutError => e
            last_error = "timeout"
            timeout_error ||= e.message
            record_provider_failure(user_settings, provider_state_name, provider_states)
            agent_run.record_provider_attempt(attempt_label, success: false, error_type: "timeout")
            logger.warn(message: "agent_execution.provider_timeout", provider: provider, agent_run_id: agent_run.id, error: e.message)
            break
          rescue ProviderExecutionError => e
            last_error = "error"
            record_provider_failure(user_settings, provider_state_name, provider_states)
            agent_run.record_provider_attempt(attempt_label, success: false, error_type: "error")
            logger.warn(message: "agent_execution.provider_failed", provider: provider, agent_run_id: agent_run.id, error: e.message)
          end
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

        # All providers exhausted. Timeout takes precedence over rate_limited
        # because it indicates an actual execution attempt that should trigger
        # ProcessRunQueueJob to re-schedule work.
        if timeout_error.present?
          agent_run.timeout!(error: timeout_error) unless agent_run.finished?
          ProcessRunQueueJob.perform_later
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

    class ProviderExecutionError < StandardError; end
    class ProviderTimeoutError < StandardError; end
    class InfiniteLoopError < StandardError; end
    CommandContext = Struct.new(:provider_candidate, :provider, :command_prefix, :user, keyword_init: true)

    private

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
    # @rate_limit_fallback_keys) and handled during execution; they do not
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
            [ agent_run.agent_type ].select { |provider| self.class::AGENT_COMMANDS.key?(provider) }
          end
      end

      @rate_limit_fallback_keys = UserSetting.rate_limit_fallback_providers(user_settings.user).to_set

      providers
    end

    # Checks if a provider is currently unavailable (rate limited or circuit open).
    #
    # @return [Boolean] true if provider should be skipped
    def provider_unavailable?(user_settings, provider_state_name, provider_states)
      state = provider_states[provider_state_name]
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

    # Returns the canonical settings-level provider name for a given agent type.
    def canonical_provider(provider)
      AGENT_TYPE_TO_PROVIDER.fetch(provider, provider)
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
      provider = provider_command_key(provider_candidate, agent_run, user_settings.user)

      command_prefix = AGENT_COMMANDS[provider]
      unless command_prefix
        raise ProviderExecutionError, "Unsupported provider: #{provider}"
      end

      prompt = augment_prompt_for_goal(agent_run, prompt)
      command_context = CommandContext.new(
        provider_candidate: provider_candidate,
        provider: provider,
        command_prefix: command_prefix,
        user: user_settings.user
      )
      command = build_command(command_context, prompt)
      command_env = command_env_for(command_context)

      pre_agent_sha = capture_head_sha(container_service, agent_run)

      raise ProviderExecutionError, "Agent run already finished with status #{agent_run.status}" if agent_run.finished?

      # Only start! on first provider attempt.
      agent_run.start! unless agent_run.running?

      agent_run.log!("system", "Starting #{provider} agent in container")
      agent_run.log!("system", "Prompt: #{prompt.truncate(500)}")

      effective_timeout = if agent_run.create_issue_goal?
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

      effective_idle_timeout = if agent_run.create_issue_goal?
        user_settings&.issue_goal_idle_timeout_seconds || DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT
      elsif agent_run.review_goal?
        user_settings&.review_goal_idle_timeout_seconds || DEFAULT_REVIEW_GOAL_IDLE_TIMEOUT
      end

      # Periodic heartbeats during container execution complement the
      # checkpoint heartbeats at provider attempt boundaries (lines 106, 129).
      # Provider calls can run for many minutes, so without periodic
      # heartbeats the 120s heartbeat_timeout would fire mid-execution.
      result = with_periodic_heartbeat("executing", provider, agent_run: agent_run) do
        container_service.execute(command, timeout: effective_timeout, idle_timeout: effective_idle_timeout, env: command_env)
      end

      if result.success?
        output_present = result[:stdout].present? || result[:stderr].present?
        agent_run.log!("system", "Agent execution succeeded with #{provider}")
        return { pre_agent_sha: pre_agent_sha, output_present: output_present }
      end

      output = (result[:stderr].presence || result[:stdout]).to_s.strip
      rate_limit_output = strip_prompt_echo(output, prompt)

      # Check if this is a rate limit error
      if rate_limit_error?(rate_limit_output)
        reset_at = parse_rate_limit_reset(rate_limit_output)
        raise ProviderRateLimitError.new("Rate limited by #{provider}", reset_at: reset_at)
      end

      # Other execution error
      raise ProviderExecutionError, "Agent exited with code #{result[:exit_code]}: #{output.truncate(500)}"
    rescue Containers::Provision::TimeoutError => e
      timeout_type = case e
      when Containers::Provision::StartupTimeoutError then "startup"
      when Containers::Provision::IdleTimeoutError then "idle"
      else "wall_clock"
      end
      raise ProviderTimeoutError, "#{timeout_type}_timeout: #{e.message}"
    end

    # Checks if the agent run is stuck in an infinite loop by analyzing
    # recent output logs. Raises InfiniteLoopError if a loop is detected.
    def check_infinite_loop!(agent_run)
      result = AgentRuns::DetectInfiniteLoop.call(agent_run: agent_run)
      raise InfiniteLoopError, result.reason if result.loop_detected?
    end

    # Checks if the output indicates a rate limit error.
    def rate_limit_error?(output)
      return false if output.blank?

      RATE_LIMIT_PATTERNS.any? { |pattern| output.match?(pattern) }
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

    def normalize_output_text(value)
      return "" if value.nil?

      text = value.to_s
      return text.delete("\x00") if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      text.dup.force_encoding(Encoding::UTF_8).scrub.delete("\x00")
    end

    # Attempts to parse a rate limit reset time from the output.
    # Falls back to 1 hour from now if not parseable.
    #
    # Supported patterns:
    #   - "retry after 60" (seconds)
    #   - "reset at 1234567890" (unix timestamp)
    #   - "resets 5am (UTC)" or "resets 5:00am (UTC)"
    def parse_rate_limit_reset(output)
      if (match = output.match(/retry.?after:?\s*(\d+)/i))
        match[1].to_i.seconds.from_now
      elsif (match = output.match(/reset.?at:?\s*(\d+)/i))
        reset_time = Time.at(match[1].to_i)
        reset_time > Time.current ? reset_time : 1.hour.from_now
      elsif (match = output.match(/resets?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(?\s*UTC\s*\)?/i))
        hour = match[1].to_i
        minute = (match[2] || "0").to_i
        period = match[3].downcase

        hour = if period == "am"
          hour == 12 ? 0 : hour
        else
          hour == 12 ? 12 : hour + 12
        end

        reset_time = Time.current.utc.change(hour: hour, min: minute, sec: 0)
        reset_time += 1.day if reset_time <= Time.current.utc
        reset_time
      else
        1.hour.from_now
      end
    rescue StandardError
      1.hour.from_now
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

        if executor
          executor.wrap(&db_scoped)
        else
          db_scoped.call
        end
      end

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

      if provider_entry&.requires_direct_outbound?
        provider_entry.direct_outbound_exec_command(command_prefix: command_context.command_prefix, prompt: prompt)
      elsif ProviderSupport.subscription_auth_unset_vars_for(command_context.provider).any?
        subscription_auth_command(command_context.provider, command_context.command_prefix, prompt)
      else
        command_context.command_prefix + [ prompt ]
      end
    end

    def command_env_for(command_context)
      provider_entry = provider_entry_for(command_context.provider_candidate, command_context.user)
      return {} unless provider_entry&.requires_direct_outbound?

      provider_entry.direct_outbound_exec_env
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
        self.class::AGENT_COMMANDS.key?(provider_command_key(provider_candidate, nil, user))
      end
    end

    def canonical_provider_candidate(provider_candidate, user)
      provider_entry = provider_entry_for(provider_candidate, user)
      return provider_entry.provider_key if provider_entry

      canonical_provider(provider_candidate)
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

    def subscription_auth_unset_vars_for(provider)
      ProviderSupport.subscription_auth_unset_vars_for(provider)
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

      container_service = reconnect_container(agent_run)
      git_ops = Containers::GitOperations.new(
        container_service: container_service,
        agent_run: agent_run
      )

      if git_ops.commit_uncommitted_changes
        agent_run.log!("system", "Auto-committed uncommitted agent changes")
      end
    rescue => e
      logger.warn(
        message: "agent_execution.commit_uncommitted_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
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
    rescue => e
      logger.warn(
        message: "agent_execution.check_changes_failed",
        agent_run_id: agent_run.id,
        error: e.message
      )
      false
    end

    def augment_prompt_for_goal(agent_run, prompt)
      if agent_run.create_issue_goal?
        augment_prompt_for_issue_goal(agent_run, prompt)
      elsif agent_run.review_goal?
        augment_prompt_for_review_goal(agent_run, prompt)
      else
        prompt
      end
    end

    def augment_prompt_for_issue_goal(agent_run, prompt)
      repo = validated_repo_name(agent_run)
      <<~AUGMENTED
        #{prompt}

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
        curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/#{repo}/issues" \\
          -H "Content-Type: application/json" \\
          -H "X-Agent-Run-Id: $AGENT_RUN_ID" \\
          -H "X-Proxy-Token: $PROXY_TOKEN" \\
          --data-binary @"$tmpfile"
        rm -f "$tmpfile"
        ```

        Available endpoints:
        - GET  $GITHUB_API_URL/repos/#{repo}/issues — list issues
        - GET  $GITHUB_API_URL/repos/#{repo}/issues/{number} — get issue
        - POST $GITHUB_API_URL/repos/#{repo}/issues — create issue
        - PATCH $GITHUB_API_URL/repos/#{repo}/issues/{number} — update issue
        - POST $GITHUB_API_URL/repos/#{repo}/issues/{number}/comments — add comment
        - POST $GITHUB_API_URL/repos/#{repo}/issues/{number}/labels — add labels

        Do NOT push code or create a pull request. Only create the GitHub issue.
      AUGMENTED
    end

    def augment_prompt_for_review_goal(agent_run, prompt)
      repo = validated_repo_name(agent_run)
      pr_number = agent_run.source_pull_request_number
      <<~AUGMENTED
        #{prompt}

        ---
        IMPORTANT: Your goal is to REVIEW A PULL REQUEST, not to write code, create issues, or create PRs.

        Review PR ##{pr_number} in #{repo}. Examine the code changes and post review comments on the PR.

        You have access to the repository code (already cloned). To examine the code changes, either:
        - Use the GitHub API (via the proxy) to retrieve the PR's `/pulls/#{pr_number}/files` patches and review those diffs; or
        - From the cloned repo, run an explicit diff against the PR base, for example:
          `git fetch origin` then `git diff "$(git merge-base HEAD origin/main)"...HEAD`
          (replace `main` with the PR's actual base branch if different).
        You also have access to the GitHub API via a proxy for posting review comments.

        Review the code for:
        1. **Performance** — inefficient algorithms, N+1 queries, unnecessary allocations, missing caching
        2. **Security** — SQL injection, XSS, insecure deserialization, secrets in code
        3. **Best practices** — language/framework idioms, error handling, naming
        4. **Project code style** — adherence to existing conventions, indentation, file organization
        5. **Scope violations** — changes unrelated to the linked issue, unnecessary refactoring, feature creep
        6. **Issue linkage** — verify the PR actually addresses the issue it claims to fix

        Use GitHub's suggestion block syntax for concrete fixes:
        ````
        ```suggestion
        corrected code here
        ```
        ````

        Post your review using the GitHub API proxy:

        ```bash
        # Get PR details (metadata and links)
        curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/#{repo}/pulls/#{pr_number}" \\
          -H "X-Agent-Run-Id: $AGENT_RUN_ID" \\
          -H "X-Proxy-Token: $PROXY_TOKEN"

        # Get PR files
        curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/#{repo}/pulls/#{pr_number}/files" \\
          -H "X-Agent-Run-Id: $AGENT_RUN_ID" \\
          -H "X-Proxy-Token: $PROXY_TOKEN"

        # Post a review with inline comments
        # Note: "side" must be "RIGHT" (new code) or "LEFT" (deleted code) for inline comments.
        curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/#{repo}/pulls/#{pr_number}/reviews" \\
          -H "Content-Type: application/json" \\
          -H "X-Agent-Run-Id: $AGENT_RUN_ID" \\
          -H "X-Proxy-Token: $PROXY_TOKEN" \\
          -d '{
            "body": "Overall summary of the review",
            "event": "COMMENT",
            "comments": [
              {
                "path": "file.rb",
                "line": 10,
                "side": "RIGHT",
                "body": "Review comment on this line"
              }
            ]
          }'

        # Post a standalone comment on the PR (optional, supplementary only)
        curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/#{repo}/issues/#{pr_number}/comments" \\
          -H "Content-Type: application/json" \\
          -H "X-Agent-Run-Id: $AGENT_RUN_ID" \\
          -H "X-Proxy-Token: $PROXY_TOKEN" \\
          -d '{"body": "Summary review comment"}'
        ```

        IMPORTANT: You MUST post at least one PR review via the `/pulls/#{pr_number}/reviews`
        endpoint. This is how your review is tracked as complete. Standalone PR comments
        via `/issues/#{pr_number}/comments` are optional and do NOT satisfy the review requirement.

        Available endpoints:
        - GET  $GITHUB_API_URL/repos/#{repo}/pulls/#{pr_number} — get PR details
        - GET  $GITHUB_API_URL/repos/#{repo}/pulls/#{pr_number}/files — list changed files
        - POST $GITHUB_API_URL/repos/#{repo}/pulls/#{pr_number}/reviews — create review with inline comments (REQUIRED)
        - POST $GITHUB_API_URL/repos/#{repo}/issues/#{pr_number}/comments — post PR comment (optional)
        - GET  $GITHUB_API_URL/repos/#{repo}/issues/{number} — get linked issue details

        Do NOT push code, create issues, or create new pull requests. Only post review comments on PR ##{pr_number}.
      AUGMENTED
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
