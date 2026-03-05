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
      /\b429\b/,
      /quota exceeded/i,
      /(?:server|system)\s+(?:at\s+)?capacity/i,
      /(?:server|api|service)\s+overloaded/i
    ].freeze

    # Issue creation should complete quickly — use a shorter timeout than full PR runs.
    ISSUE_GOAL_TIMEOUT = 600        # 10 minutes wall clock
    ISSUE_GOAL_IDLE_TIMEOUT = 120   # 2 minutes without output = stuck

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      prompt = agent_run.effective_prompt
      raise Temporalio::Error::ApplicationError.new("No prompt available for agent run", type: "MissingPrompt") unless prompt

      user_settings = resolve_user_settings(agent_run)
      providers = build_provider_order(agent_run, user_settings)

      pre_agent_sha = nil
      last_error = nil
      last_attempted_provider = nil

      providers.each do |provider|
        # Skip unavailable providers
        if provider_unavailable?(user_settings, provider)
          agent_run.record_provider_attempt(provider, success: false, error_type: "unavailable")
          next
        end

        # Log provider switch when we have a previous actually-attempted provider
        if last_attempted_provider
          agent_run.log_provider_switch!(last_attempted_provider, provider, last_error || "fallback")
        end

        begin
          last_attempted_provider = provider
          pre_agent_sha = run_agent_with_provider(agent_run, provider, prompt)

          # Success - record and update final provider
          record_provider_success(user_settings, provider)
          agent_run.record_provider_attempt(provider, success: true)
          agent_run.update!(final_provider: provider)

          commit_uncommitted_changes(agent_run)
          has_changes = check_for_changes(agent_run, pre_agent_sha)

          return {
            agent_run_id: agent_run_id,
            success: true,
            has_changes: has_changes,
            final_provider: provider
          }
        rescue ProviderRateLimitError => e
          last_error = "rate_limited"
          persist_rate_limit(user_settings, provider, e.reset_at)
          agent_run.record_provider_attempt(provider, success: false, error_type: "rate_limited")
          logger.info(message: "agent_execution.rate_limited", provider: provider, agent_run_id: agent_run.id)
        rescue ProviderExecutionError => e
          last_error = "error"
          record_provider_failure(user_settings, provider)
          agent_run.record_provider_attempt(provider, success: false, error_type: "error")
          logger.warn(message: "agent_execution.provider_failed", provider: provider, agent_run_id: agent_run.id, error: e.message)
        end
      end

      # All providers exhausted. Preserve any more specific terminal state
      # already set by provider execution (e.g. timeout).
      unless agent_run.finished?
        agent_run.fail!(error: "All providers exhausted: #{providers.join(', ')}")
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

    private

    # Resolves user settings for the agent run by finding the appropriate user.
    # Tries the project creator first, then falls back to the account's owner member.
    def resolve_user_settings(agent_run)
      project = agent_run.project
      account = project.account

      user = project.created_by
      user ||= account.account_memberships.find_by(role: :owner)&.user
      user ||= account.users.first

      raise Temporalio::Error::ApplicationError.new(
        "No user available for agent run settings",
        type: "MissingUser"
      ) unless user

      user.settings
    end

    # Builds the ordered list of providers to attempt.
    # Uses fallback providers if enabled, otherwise just the agent's type.
    #
    # @return [Array<String>] Provider names in priority order
    def build_provider_order(agent_run, user_settings)
      return [ agent_run.agent_type ] unless user_settings.fallback_enabled

      # Normalize agent_type to the canonical settings provider name so that
      # e.g. "claude_code" is deduplicated against "claude" in the fallback list.
      canonical = AGENT_TYPE_TO_PROVIDER.fetch(agent_run.agent_type, agent_run.agent_type)

      # Start with the agent's original type (for AGENT_COMMANDS lookup), then add
      # fallback providers that map to a different canonical name.
      providers = [ agent_run.agent_type ]
      seen = Set.new([ canonical ])

      user_settings.fallback_providers.each do |fallback|
        fallback_canonical = AGENT_TYPE_TO_PROVIDER.fetch(fallback, fallback)
        next if seen.include?(fallback_canonical)

        seen << fallback_canonical
        providers << fallback
      end

      providers.select { |p| AGENT_COMMANDS.key?(p) }
    end

    # Checks if a provider is currently unavailable (rate limited or circuit open).
    #
    # @return [Boolean] true if provider should be skipped
    def provider_unavailable?(user_settings, provider)
      canonical = canonical_provider(provider)
      state = user_settings.user.provider_states.find_by(provider_name: canonical)
      return false unless state

      # Check for circuit recovery before deciding
      state.check_circuit_recovery!(timeout: user_settings.circuit_breaker_timeout_seconds)

      state.unavailable?
    end

    # Records a rate limit for a provider.
    def persist_rate_limit(user_settings, provider, reset_at = nil)
      state = user_settings.provider_state_for(canonical_provider(provider))
      state.mark_rate_limited!(reset_at: reset_at)
    end

    # Records a successful provider execution.
    def record_provider_success(user_settings, provider)
      canonical = canonical_provider(provider)
      state = user_settings.user.provider_states.find_by(provider_name: canonical)
      state&.record_success!
    end

    # Records a failed provider execution.
    def record_provider_failure(user_settings, provider)
      state = user_settings.provider_state_for(canonical_provider(provider))
      state.record_failure!(threshold: user_settings.circuit_breaker_failure_threshold)
    end

    # Returns the canonical settings-level provider name for a given agent type.
    def canonical_provider(provider)
      AGENT_TYPE_TO_PROVIDER.fetch(provider, provider)
    end

    # Runs the agent with a specific provider.
    # Raises ProviderRateLimitError or ProviderExecutionError on failure.
    #
    # @return [String, nil] the HEAD SHA before the agent ran
    def run_agent_with_provider(agent_run, provider, prompt)
      container_service = reconnect_container(agent_run)

      command_prefix = AGENT_COMMANDS[provider]
      unless command_prefix
        raise ProviderExecutionError, "Unsupported provider: #{provider}"
      end

      prompt = augment_prompt_for_issue_goal(agent_run, prompt)
      command = command_prefix + [ prompt ]

      pre_agent_sha = capture_head_sha(container_service, agent_run)

      # Only start! on first provider attempt
      unless agent_run.running?
        agent_run.start!
      end

      agent_run.log!("system", "Starting #{provider} agent in container")
      agent_run.log!("system", "Prompt: #{prompt.truncate(500)}")

      effective_timeout = agent_run.create_issue_goal? ? ISSUE_GOAL_TIMEOUT : agent_timeout
      effective_idle_timeout = agent_run.create_issue_goal? ? ISSUE_GOAL_IDLE_TIMEOUT : nil

      result = container_service.execute(command, timeout: effective_timeout, idle_timeout: effective_idle_timeout)

      if result.success?
        agent_run.log!("system", "Agent execution succeeded with #{provider}")
        return pre_agent_sha
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
      agent_run.timeout!(error: "#{timeout_type}_timeout: #{e.message}")
      ProcessRunQueueJob.perform_later
      raise ProviderExecutionError, "#{timeout_type}_timeout: #{e.message}"
    end

    # Checks if the output indicates a rate limit error.
    def rate_limit_error?(output)
      return false if output.blank?

      RATE_LIMIT_PATTERNS.any? { |pattern| output.match?(pattern) }
    end

    # Attempts to parse a rate limit reset time from the output.
    # Falls back to 60 seconds from now if not parseable.
    def parse_rate_limit_reset(output)
      # Try to find common patterns like "retry after X seconds" or timestamps
      if (match = output.match(/retry.?after:?\s*(\d+)/i))
        match[1].to_i.seconds.from_now
      elsif (match = output.match(/reset.?at:?\s*(\d+)/i))
        Time.at(match[1].to_i)
      else
        60.seconds.from_now
      end
    rescue StandardError
      60.seconds.from_now
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
