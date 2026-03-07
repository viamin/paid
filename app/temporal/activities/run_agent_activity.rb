# frozen_string_literal: true

module Activities
  class RunAgentActivity < BaseActivity
    activity_name "RunAgent"

    # Maps agent_type/provider to the CLI command used inside the container.
    # Each entry is an array of command parts; the prompt is appended as the last argument.
    AGENT_COMMANDS = {
      "claude_code" => %w[claude --print --output-format=text --dangerously-skip-permissions -p],
      "claude" => %w[claude --print --output-format=text --dangerously-skip-permissions -p],
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
      /(?:server|system)\s+(?:at\s+)?capacity/i,
      /(?:server|api|service)\s+overloaded/i,
      /out of (?:extra )?usage/i,
      /usage limit/i
    ].freeze

    # Issue creation should complete quickly — use a shorter timeout than full PR runs.
    ISSUE_GOAL_TIMEOUT = 600        # 10 minutes wall clock
    ISSUE_GOAL_IDLE_TIMEOUT = 120   # 2 minutes without output = stuck

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

      prompt = agent_run.effective_prompt
      raise Temporalio::Error::ApplicationError.new("No prompt available for agent run", type: "MissingPrompt") unless prompt

      user_settings = resolve_user_settings(agent_run)
      providers = build_provider_order(agent_run, user_settings)
      provider_states = load_provider_state_cache(user_settings.user, providers)

      pre_agent_sha = nil
      last_error = nil
      last_attempted_provider = nil
      timeout_error = nil
      rate_limit_reset_at = nil

      providers.each do |provider|
        # Skip unavailable providers
        if provider_unavailable?(user_settings, provider, provider_states)
          agent_run.record_provider_attempt(provider, success: false, error_type: "unavailable")
          next
        end

        # Log provider switch when we have a previous actually-attempted provider
        if last_attempted_provider
          agent_run.log_provider_switch!(last_attempted_provider, provider, last_error || "fallback")
        end

        begin
          last_attempted_provider = provider
          provider_result = run_agent_with_provider(agent_run, provider, prompt)
          pre_agent_sha = provider_result.fetch(:pre_agent_sha)

          # Success - record and update final provider
          record_provider_success(user_settings, provider, provider_states)
          agent_run.record_provider_attempt(provider, success: true)
          agent_run.update!(final_provider: provider)

          commit_uncommitted_changes(agent_run)
          has_changes = check_for_changes(agent_run, pre_agent_sha)

          if !has_changes && !provider_result.fetch(:output_present)
            agent_run.log!("system", "Provider completed with no output and no changes")
          end

          return {
            agent_run_id: agent_run_id,
            success: true,
            has_changes: has_changes,
            final_provider: provider
          }
        rescue ProviderRateLimitError => e
          last_error = "rate_limited"
          rate_limit_reset_at = e.reset_at
          persist_rate_limit(user_settings, provider, provider_states, e.reset_at)
          agent_run.record_provider_attempt(provider, success: false, error_type: "rate_limited")
          logger.info(message: "agent_execution.rate_limited", provider: provider, agent_run_id: agent_run.id)
        rescue ProviderTimeoutError => e
          last_error = "timeout"
          timeout_error ||= e.message
          record_provider_failure(user_settings, provider, provider_states)
          agent_run.record_provider_attempt(provider, success: false, error_type: "timeout")
          logger.warn(message: "agent_execution.provider_timeout", provider: provider, agent_run_id: agent_run.id, error: e.message)
        rescue ProviderExecutionError => e
          last_error = "error"
          record_provider_failure(user_settings, provider, provider_states)
          agent_run.record_provider_attempt(provider, success: false, error_type: "error")
          logger.warn(message: "agent_execution.provider_failed", provider: provider, agent_run_id: agent_run.id, error: e.message)
        end
      end

      # All providers exhausted. Preserve any more specific terminal state
      # already set by provider execution (e.g. timeout).
      if !agent_run.finished? && last_error == "rate_limited"
        provider_list = providers.any? ? providers.join(", ") : "none"
        agent_run.rate_limit!(
          error: "All providers rate limited: #{provider_list}",
          reset_at: rate_limit_reset_at
        )
      elsif timeout_error.present?
        agent_run.timeout!(error: timeout_error) unless agent_run.finished?
        ProcessRunQueueJob.perform_later
      elsif !agent_run.finished?
        provider_list = providers.any? ? providers.join(", ") : "none"
        agent_run.fail!(error: "All providers exhausted: #{provider_list}")
      end
      raise Temporalio::Error::ApplicationError.new(
        "All providers exhausted",
        type: "AllProvidersExhausted"
      )
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

    private

    # Resolves user settings for the agent run by finding the appropriate user.
    # Tries the project creator first, then falls back to the account's owner member.
    def resolve_user_settings(agent_run)
      AgentRuns::UserSettingsResolver.call(project: agent_run.project, strict: true)
    rescue AgentRuns::UserSettingsResolver::MissingUserError
      raise Temporalio::Error::ApplicationError.new(
        "No user available for agent run settings",
        type: "MissingUser"
      )
    end

    # Builds the ordered list of providers to attempt.
    # Uses fallback providers if enabled, otherwise just the agent's type.
    #
    # @return [Array<String>] Provider names in priority order
    def build_provider_order(agent_run, user_settings)
      self.class.provider_order(
        agent_type: agent_run.agent_type,
        fallback_enabled: user_settings.fallback_enabled,
        fallback_providers: user_settings.fallback_providers
      )
    end

    # Checks if a provider is currently unavailable (rate limited or circuit open).
    #
    # @return [Boolean] true if provider should be skipped
    def provider_unavailable?(user_settings, provider, provider_states)
      canonical = canonical_provider(provider)
      state = provider_states[canonical]
      return false unless state

      # Check for circuit recovery before deciding
      state.check_circuit_recovery!(timeout: user_settings.circuit_breaker_timeout_seconds)

      state.unavailable?
    end

    # Records a rate limit for a provider.
    def persist_rate_limit(user_settings, provider, provider_states, reset_at = nil)
      state = provider_state_for(user_settings, provider, provider_states)
      state.mark_rate_limited!(reset_at: reset_at)
    end

    # Records a successful provider execution.
    def record_provider_success(user_settings, provider, provider_states = nil)
      canonical = canonical_provider(provider)
      state = provider_states ? provider_states[canonical] : user_settings.user.provider_states.find_by(provider_name: canonical)
      state&.record_success!
    end

    # Records a failed provider execution.
    def record_provider_failure(user_settings, provider, provider_states)
      state = provider_state_for(user_settings, provider, provider_states)
      state.record_failure!(threshold: user_settings.circuit_breaker_failure_threshold)
    end

    # Returns the canonical settings-level provider name for a given agent type.
    def canonical_provider(provider)
      AGENT_TYPE_TO_PROVIDER.fetch(provider, provider)
    end

    def provider_state_for(user_settings, provider, provider_states)
      canonical = canonical_provider(provider)
      provider_states[canonical] ||= user_settings.provider_state_for(canonical)
    end

    def load_provider_state_cache(user, providers)
      canonical_providers = providers.map { |provider| canonical_provider(provider) }.uniq
      user.provider_states.where(provider_name: canonical_providers).index_by(&:provider_name)
    end

    # Runs the agent with a specific provider.
    # Raises ProviderRateLimitError, ProviderTimeoutError, or ProviderExecutionError on failure.
    #
    # @return [Hash] The pre-agent SHA and whether output was present
    def run_agent_with_provider(agent_run, provider, prompt)
      container_service = reconnect_container(agent_run)

      command_prefix = AGENT_COMMANDS[provider]
      unless command_prefix
        raise ProviderExecutionError, "Unsupported provider: #{provider}"
      end

      prompt = augment_prompt_for_issue_goal(agent_run, prompt)
      command = command_prefix + [ prompt ]

      pre_agent_sha = capture_head_sha(container_service, agent_run)

      raise ProviderExecutionError, "Agent run already finished with status #{agent_run.status}" if agent_run.finished?

      # Only start! on first provider attempt.
      agent_run.start! unless agent_run.running?

      agent_run.log!("system", "Starting #{provider} agent in container")
      agent_run.log!("system", "Prompt: #{prompt.truncate(500)}")

      effective_timeout = agent_run.create_issue_goal? ? ISSUE_GOAL_TIMEOUT : agent_timeout
      effective_idle_timeout = agent_run.create_issue_goal? ? ISSUE_GOAL_IDLE_TIMEOUT : nil

      result = container_service.execute(command, timeout: effective_timeout, idle_timeout: effective_idle_timeout)

      if result.success?
        output_present = result[:stdout].present? || result[:stderr].present?
        agent_run.log!("system", "Agent execution succeeded with #{provider}")
        return { pre_agent_sha: pre_agent_sha, output_present: output_present }
      end

      output = (result[:stderr].presence || result[:stdout]).to_s.strip

      # Check if this is a rate limit error
      if rate_limit_error?(output)
        reset_at = parse_rate_limit_reset(output)
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

    # Checks if the output indicates a rate limit error.
    def rate_limit_error?(output)
      return false if output.blank?

      RATE_LIMIT_PATTERNS.any? { |pattern| output.match?(pattern) }
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

    def augment_prompt_for_issue_goal(agent_run, prompt)
      return prompt unless agent_run.create_issue_goal?

      # full_name is "owner/repo" from our DB (set during GitHub import).
      # Validate format to prevent injection in the shell command example.
      repo = agent_run.project.full_name
      unless repo.match?(%r{\A[A-Za-z0-9\-_.]+/[A-Za-z0-9\-_.]+\z})
        raise Temporalio::Error::ApplicationError.new(
          "Invalid repository name format: #{repo.inspect}",
          type: "InvalidRepoName"
        )
      end
      <<~AUGMENTED
        #{prompt}

        ---
        IMPORTANT: Your goal is to CREATE A GITHUB ISSUE, not to write code or create a PR.

        You have access to the GitHub API via a proxy. Use curl to create the issue:

        ```bash
        curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/#{repo}/issues" \\
          -H "Content-Type: application/json" \\
          -H "X-Agent-Run-Id: $AGENT_RUN_ID" \\
          -H "X-Proxy-Token: $PROXY_TOKEN" \\
          -d '{"title": "Issue title", "body": "Issue description", "labels": []}'
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

    def reconnect_container(agent_run)
      raise Temporalio::Error::ApplicationError.new(
        "No container provisioned for agent run #{agent_run.id}",
        type: "ContainerNotProvisioned"
      ) if agent_run.container_id.blank?

      Containers::Provision.reconnect(
        agent_run: agent_run,
        container_id: agent_run.container_id
      )
    end

    def agent_timeout
      Rails.application.config.x.agent_timeout
    end
  end
end
