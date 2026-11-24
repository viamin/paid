# frozen_string_literal: true

module Llm
  # Routes application text through owned, configured runners and credentials.
  class Request
    MAX_ATTEMPTS = 5
    FROZEN_ATTEMPT_TRACES = ObjectSpace::WeakMap.new
    FROZEN_ATTEMPT_TRACES_LOCK = Mutex.new

    def self.call(...) = new(...).call

    def self.attempt_trace_for(subject)
      return unless subject

      subject.instance_variable_get(:@llm_request_attempt_trace) ||
        FROZEN_ATTEMPT_TRACES_LOCK.synchronize { FROZEN_ATTEMPT_TRACES[subject] }
    end

    def initialize(prompt:, timeout:, agent_run: nil, project: nil, account: nil, user: nil, model: nil, runner: nil,
      fallback_runner_identifiers: [], per_runner_timeout: nil, response_validator: nil, request_id: nil, attempt_id: nil,
      clock: Process.method(:clock_gettime))
      @runner_identifier = runner
      @model = model
      @agent_run = agent_run
      @project = agent_run&.project || project
      @account = @project&.account || account || user&.account || Current.account
      @user = @project&.effective_owner || user || account&.fallback_owner || Current.user || @account&.fallback_owner
      @prompt = prompt
      @timeout = timeout
      @fallback_runner_identifiers = fallback_runner_identifiers
      @per_runner_timeout = per_runner_timeout
      @response_validator = response_validator
      @permanent_failure = nil
      @transient_failure = nil
      @unsuccessful_response = nil
      @invalid_response = nil
      @eligible_route = false
      @missing_managed_credential = false
      @request_id = request_id
      @attempt_id = attempt_id
      @attempts = []
      @clock = clock
    end

    def call # @spec LLM-ROUTING-001 LLM-ROUTING-002 LLM-ROUTING-003 LLM-ROUTING-005 LLM-ROUTING-006 LLM-ROUTING-008 LLM-ROUTING-009 LLM-ROUTING-012 LLM-ROUTING-013 MODEL-POLICY-015 MODEL-POLICY-016 MODEL-POLICY-024 PARTIAL-CLOSEOUT-031 PARTIAL-CLOSEOUT-048 PARTIAL-CLOSEOUT-049 PARTIAL-CLOSEOUT-058 PARTIAL-CLOSEOUT-059
      unless @user && (!@account || @user.account_id == @account.id)
        raise configuration_error("No owning user for this LLM request")
      end
      runners = candidate_runners
      raise configuration_error("No eligible configured runner for this LLM request") if runners.empty?

      @required_zdr = @project&.restricted? || agent_run&.external_metadata.to_h["zdr_required"] == true ||
        runners.first.zero_data_retention?

      @deadline = monotonic_now + @timeout
      runners.each do |runner|
        remaining = @deadline - monotonic_now
        if remaining <= 0
          # The overall budget is spent: no later candidate can be attempted.
          # The timeout is recorded rather than raised so an earlier permanent
          # failure still outranks it (#5002 review).
          skipped_attempt(runner, allocated_ms: 0, reason: "deadline_exhausted")
          record_failure(AgentHarness::TimeoutError.new("LLM request timeout exhausted"))
          break
        end
        response = attempt_runner(runner, remaining: remaining)
        return response if response
      end

      resolve_outcome
    end

    private

    # The run's pinned runner first, then the configured fallback runners.
    # Identifiers that do not resolve to a runner the caller owns are dropped.
    def candidate_runners
      if @runner_identifier
        [ Runner.for_identifier(@user, @runner_identifier) ].compact
      elsif agent_run&.effective_runner_record
        [ agent_run.effective_runner_record, *Array(@fallback_runner_identifiers).filter_map { |identifier|
          Runner.for_identifier(@user, identifier)
        } ].uniq
      else
        selected_runners
      end
    end

    # One candidate attempt. Returns the successful response, or nil when the
    # candidate produced no usable answer; every failure is recorded for the
    # final outcome.
    def attempt_runner(runner, remaining:)
      timeout = @per_runner_timeout ? [ remaining.ceil, @per_runner_timeout ].min : remaining.ceil
      attempt = start_attempt(runner, allocated_ms: timeout * 1000)
      candidate_deadline = [ @deadline, attempt.fetch(:started_at) + timeout ].min
      candidate_required_zdr = @required_zdr || runner.zero_data_retention?
      policy = runner.effective_privacy_policy(project: @project, required_zdr: candidate_required_zdr)
      return skipped(attempt, "privacy_policy") unless policy.eligible

      @eligible_route = true
      @required_zdr = candidate_required_zdr
      # A candidate that cannot serve this request at all is skipped, not
      # failed: it must never mask another runner's failure (#5002 review).
      return skipped(attempt, "unavailable") unless runner_available?(runner)
      unless runner.api_key? || managed_credential_available?(runner)
        @missing_managed_credential = true
        return skipped(attempt, "missing_managed_credential")
      end

      response = perform_request(runner, timeout:, deadline: candidate_deadline, attempt:)
      if !response.respond_to?(:success?) || response.success?
        if valid_response?(response)
          finish_attempt(attempt, "success")
          return attach_trace(response, attempt_trace)
        end

        # A transport-successful response can still be unusable for a caller's
        # public response contract. Keep only the response object in memory so
        # the caller can safely classify it after all authorized candidates
        # have been exhausted; never log or persist its output here.
        @invalid_response = response
        @invalid_attempt = attempt
        finish_attempt(attempt, "invalid_response")
        return
      end

      @unsuccessful_response ||= response
      @unsuccessful_attempt ||= attempt
      finish_attempt(attempt, "unsuccessful_response")
      nil
    rescue AgentHarness::Error => failure
      Rails.logger.warn(message: "llm.request_runner_failed", runner_id: runner.id,
        project_id: @project&.id, agent_run_id: agent_run&.id, error_class: failure.class.name)
      finish_attempt(attempt, normalized_outcome(failure))
      record_failure(failure, attempt:)
      nil
    ensure
      finish_attempt(attempt, "unknown") if attempt && attempt[:outcome].nil?
    end

    # A permanent failure — an expired credential or a violated model policy —
    # is tracked apart from a transport failure so that it can outrank it
    # (#5002 review).
    def record_failure(failure, attempt: nil)
      if retryable_failure?(failure)
        # The final eligible transport attempt is the terminal transient route.
        # Keep an earlier permanent failure separately; it still wins below.
        @transient_failure = failure
        @transient_attempt = attempt
      else
        unless @permanent_failure
          @permanent_failure = failure
          @permanent_attempt = attempt
        end
      end
    end

    # One final outcome for the request. A permanent failure outranks any
    # transport outcome: the request cannot succeed until an operator
    # reconnects a credential or fixes the model policy, so a later transient
    # failure must not hide it (#5002 review).
    def resolve_outcome
      raise attach_trace(@permanent_failure, attempt_trace(selected_attempt: @permanent_attempt)) if @permanent_failure
      # A later transport-successful response rejected by the caller contract
      # is more actionable than an earlier transport interruption. Return it
      # so the caller can retain its bounded structural diagnostics; a valid
      # later response would already have returned from the routing loop.
      return attach_trace(@invalid_response, attempt_trace(selected_attempt: @invalid_attempt)) if @invalid_response
      raise attach_trace(@transient_failure, attempt_trace(selected_attempt: @transient_attempt)) if @transient_failure
      return attach_trace(@unsuccessful_response, attempt_trace(selected_attempt: @unsuccessful_attempt)) if @unsuccessful_response
      if @missing_managed_credential
        raise configuration_error("No managed subscription credential is available for isolated text requests")
      end
      raise configuration_error("No eligible configured runner for this LLM request") if @eligible_route

      raise configuration_error("No eligible configured runner can satisfy the required zero data retention policy")
    end

    def retryable_failure?(failure)
      !failure.is_a?(AgentHarness::AuthenticationError) && !failure.is_a?(AgentHarness::ConfigurationError)
    end

    def valid_response?(response)
      return true unless @response_validator

      @response_validator.call(response)
    rescue StandardError => error
      Rails.logger.warn(message: "llm.request_response_rejected", project_id: @project&.id,
        agent_run_id: agent_run&.id, error_class: error.class.name)
      false
    end

    # A candidate that is discarded, owned by another account, or not permitted
    # for this usage cannot serve the request. It is skipped instead of failed
    # so that an unavailable fallback neither masks another runner's failure nor
    # turns a retryable transport failure into a permanent one (#5002 review).
    def runner_available?(runner)
      runner.present? && !runner.discarded? && runner.user_id == @user&.id && permitted_usage?(runner)
    end

    # @spec LLM-ROUTING-011 SUBSCRIPTION-RUNNER-AUTH-006
    def managed_credential_available?(runner)
      Runners::ManagedCredentialLifecycle.credential_for(account: runner.user.account, runner_key: runner.runner_key).present?
    end

    def perform_request(runner, timeout:, deadline:, attempt:)
      if runner.api_key? && runner.effective_api_secret.blank?
        raise AgentHarness::ConfigurationError, "Selected runner is missing its API credential"
      end
      key = RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym
      config = AgentHarness.build_config(key)
      config.externally_sandboxed = true
      executor = executor_for(runner, timeout: timeout, deadline: deadline)
      provider = AgentHarness.provider_class(key).new(config: config, executor: executor)
      runtime = runtime_for(runner)
      runtime = subscription_runtime(provider, runtime) unless runner.api_key?
      attempt[:provider] = runtime.api_provider.presence || runner.runner_key
      attempt[:model] = runtime.model
      validate_model_policy!(runner, @policy_model_id || runtime.model)
      response = provider.send_message(prompt: @prompt, timeout: timeout, mode: :text, tools: :none, dangerous_mode: false,
        mcp_servers: [], provider_runtime: runtime)
      attempt[:provider] = response.provider.to_s if response.respond_to?(:provider) && response.provider.present?
      attempt[:model] = response.model if response.respond_to?(:model) && response.model.present?
      response
    ensure
      executor&.close
    end

    attr_reader :agent_run

    def start_attempt(runner, allocated_ms:)
      attempt = {
        ordinal: @attempts.size + 1,
        runner_id: runner.id,
        runner: runner.routing_key,
        allocated_ms: allocated_ms,
        phase: "unknown",
        started_at: monotonic_now
      }
      @attempts << attempt
      attempt
    end

    def skipped_attempt(runner, allocated_ms:, reason:)
      attempt = start_attempt(runner, allocated_ms:)
      finish_attempt(attempt, "skipped", skip_reason: reason)
      attempt
    end

    def skipped(attempt, reason)
      finish_attempt(attempt, "skipped", skip_reason: reason)
      nil
    end

    def finish_attempt(attempt, outcome, skip_reason: nil)
      return if attempt[:outcome]

      attempt[:outcome] = outcome
      attempt[:skip_reason] = skip_reason if skip_reason
      started_at = attempt.delete(:started_at)
      attempt[:elapsed_ms] = ((monotonic_now - started_at) * 1000).round if started_at
    end

    def normalized_outcome(failure)
      return "timeout" if failure.is_a?(AgentHarness::TimeoutError)
      return "authentication_unavailable" if failure.is_a?(AgentHarness::AuthenticationError)
      return "configuration_error" if failure.is_a?(AgentHarness::ConfigurationError)

      "transport_error"
    end

    def attempt_trace(selected_attempt: nil)
      {
        request_id: @request_id,
        attempt_id: @attempt_id,
        selected_attempt_ordinal: selected_attempt&.fetch(:ordinal),
        attempts: @attempts.first(MAX_ATTEMPTS).map { |attempt| attempt.except(:started_at).compact }
      }.compact
    end

    def attach_trace(subject, trace)
      subject.instance_variable_set(:@llm_request_attempt_trace, trace) if subject
      subject
    rescue FrozenError
      FROZEN_ATTEMPT_TRACES_LOCK.synchronize { FROZEN_ATTEMPT_TRACES[subject] = trace } if subject
      subject
    end

    def configuration_error(message)
      attach_trace(AgentHarness::ConfigurationError.new(message), attempt_trace)
    end

    def validate_model_policy!(runner, model_id)
      return unless @project

      model = LlmModel.find_by(model_id: model_id)
      provider = model&.provider || Runners::DefaultTierModelIds::RUNNER_KEY_TO_MODEL_PROVIDER[runner.runner_key] || runner.direct_outbound_llm_model_provider
      preferences = @project.model_preferences
      required = preferences["required_model_id"]
      if model&.operator_active_override == false || Array(preferences["excluded_model_ids"]).include?(model_id) ||
          (required.present? && required != model_id) ||
          (@project.llm_provider_routing_restricted? && (provider.blank? || !@project.llm_provider_allowed?(provider))) ||
          !Runners::VerifiedModels.within_tier_bounds?(model, preferences, agent_run&.goal)
        raise AgentHarness::ConfigurationError, "Selected model violates project model policy"
      end
    end

    def permitted_usage?(runner)
      agent_run&.effective_runner_record ? runner.enabled_for_agent_runs? : runner.enabled_for_chat?
    end

    def selected_runners
      return unless @user && (!@account || @user.account_id == @account.id)

      RunnerSelection.available_candidates(user: @user)
    end

    def executor_for(runner, timeout:, deadline:)
      Containers::StandaloneTextExecutor.new(account: @account || runner.user.account, runner: runner, timeout: timeout,
        deadline: deadline)
    end

    def monotonic_now
      @clock.call(Process::CLOCK_MONOTONIC)
    end

    def subscription_runtime(provider, runtime)
      AgentHarness::ProviderRuntime.new(model: runtime.model, api_provider: runtime.api_provider,
        base_url: runtime.base_url, env: runtime.env, unset_env: runtime.unset_env | provider.subscription_unset_vars,
        flags: runtime.flags, metadata: runtime.metadata, privacy_routing: runtime.privacy_routing)
    end

    def runtime_for(runner)
      tier = agent_run&.model_selection&.tier.presence || "mid"
      resolved = Runners::ResolveTierModel.call(runner: runner, tier: tier,
        user: runner.user, project: @project, goal: agent_run&.goal)
      if @model.present?
        compatible = Runners::ModelCompatibility.call(runner_key: runner.runner_key, model_id: @model, auth_type: runner.auth_type)
        unless !compatible.unsupported? && Runners::VerifiedModels.new(runner).permitted?(@model, project: @project, goal: agent_run&.goal)
          raise AgentHarness::ConfigurationError, "Requested model is not permitted for the selected runner"
        end
        resolved = Runners::ResolveTierModel::Result.new(model_id: @model)
      end
      configured = runner.agent_harness_runner_runtime(project: @project, required_zdr: @required_zdr) unless runner.free_model_policy?
      if configured && resolved.failure? && resolved.error_type == :missing_model
        @policy_model_id = runner.direct_outbound_model_id.presence || configured.model
        return configured
      end
      raise AgentHarness::ConfigurationError, "No permitted model for this LLM request: #{resolved.error}" if resolved.failure?
      @policy_model_id = resolved.model_id
      if runner.free_model_policy?
        return runner.free_model_policy_runner_runtime(
          project: @project, model_id: resolved.model_id, required_zdr: @required_zdr
        )
      end

      env = configured&.env || {}
      env = env.merge("OPENAI_API_KEY" => runner.effective_api_secret) if runner.api_key? && runner.runner_key == "codex"

      AgentHarness::ProviderRuntime.new(
        model: runner.qualified_model_for(resolved.model_id),
        api_provider: configured&.api_provider, base_url: configured&.base_url,
        env: env, unset_env: configured&.unset_env || [],
        flags: configured&.flags || [], metadata: configured&.metadata || {},
        privacy_routing: configured&.privacy_routing
      )
    end
  end
end
