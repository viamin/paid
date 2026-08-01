# frozen_string_literal: true

module Containers
  # Resolves container host placement attributes for a new AgentRun.
  #
  # Extracted from Projects::AgentRunsController so the lid_planning path in
  # ProjectsController can reuse the same resolution logic (RDR-051 phase 3).
  #
  # Callers that catch InvalidDockerHostSelectionError SHOULD surface the
  # message to the user as an alert.
  class ResolveHostForRun
    InvalidDockerHostSelectionError = Class.new(StandardError)

    API_KEY_PROXY_SUBSCRIPTION_RUNNERS = %w[codex].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, runner:, account:, requested_container_host: nil)
      @project = project
      @runner = runner
      @account = account
      @requested_container_host = requested_container_host
    end

    # Returns { container_host: String|nil, external_metadata: Hash|nil }.
    # external_metadata is only present when non-empty.
    def call
      selected_host = resolve_identifier
      metadata = selection_metadata(selected_host)

      if capacity_aware_fallback?
        selected_host = nil
      end

      attributes = { container_host: selected_host }
      attributes[:external_metadata] = metadata if metadata.present?
      attributes
    end

    private

    attr_reader :project, :runner, :account, :requested_container_host

    def capacity_aware_fallback?
      requested_container_host.blank? &&
        project.effective_preferred_docker_host_identifier.present? &&
        account.tenant_setting&.docker_host_fallback_behavior == HostRegistry::FALLBACK_CAPACITY_AWARE
    end

    def resolve_identifier
      eligible = docker_host_selection_context[:eligible_hosts].index_by(&:identifier)

      if requested_container_host.present?
        requested = eligible[requested_container_host]
        raise InvalidDockerHostSelectionError, "Please choose a healthy compatible Docker host." unless requested

        return requested.identifier
      end

      preferred_identifier = project.effective_preferred_docker_host_identifier
      preferred_host = eligible[preferred_identifier]
      return preferred_host.identifier if preferred_host

      fallback_behavior = account.tenant_setting&.docker_host_fallback_behavior
      return nil unless preferred_identifier.present? && fallback_behavior == HostRegistry::FALLBACK_FIRST_HEALTHY

      eligible.values.find(&:fallback_eligible?)&.identifier
    end

    def selection_metadata(selected_host)
      if requested_container_host.present?
        return { "container_host_selection" => { "explicit_host" => selected_host } }
      end

      preferred_identifier = project.effective_preferred_docker_host_identifier.presence
      return {} if preferred_identifier.blank?

      selection = { "preferred_host" => preferred_identifier }
      fallback_behavior = account.tenant_setting&.docker_host_fallback_behavior
      selection["fallback"] = fallback_behavior if fallback_behavior.present?

      { "container_host_selection" => selection }
    end

    def docker_host_selection_context
      auth_source = runner&.subscription? ? subscription_auth_source_for(runner) : nil
      {
        auth_source: auth_source,
        eligible_hosts: eligible_docker_hosts(auth_source)
      }
    end

    def eligible_docker_hosts(auth_source)
      account.docker_hosts.enabled.ordered.select do |host|
        docker_host_eligible?(host, auth_source)
      end
    end

    def docker_host_eligible?(host, auth_source)
      return false unless host.placement_ready?

      return true if auth_source.nil?

      subscription_auth_eligible?(host, auth_source).eligible?
    end

    def subscription_auth_eligible?(host, auth_source)
      Runners::SubscriptionAuthEligibility.call(
        backend: docker_host_backend_capabilities(host),
        auth_source: auth_source,
        proxy_reachable: host.required_network_status == "ready"
      )
    end

    def docker_host_backend_capabilities(host)
      Struct.new(:identifier, :supports_host_paths?).new(host.identifier, host.local?)
    end

    def subscription_auth_source_for(runner)
      runner_key = runner.runner_key.to_s
      credential = managed_subscription_credential_for(runner_key, require_active: false)

      if credential
        return Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: runner_key,
          auth_mode: :managed,
          credential_state: managed_credential_state_for(runner_key, credential)
        )
      end

      if api_key_proxy_subscription_auth_for?(runner_key)
        return Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: runner_key,
          auth_mode: :api_key_proxy
        )
      end

      Runners::SubscriptionAuthEligibility::AuthSource.new(
        runner_key: runner_key,
        auth_mode: :host_forwarded
      )
    end

    def api_key_proxy_subscription_auth_for?(runner_key)
      API_KEY_PROXY_SUBSCRIPTION_RUNNERS.include?(runner_key)
    end

    def managed_subscription_credential_for(runner_key, require_active: true)
      scope = account.runner_credentials.for_runner(runner_key)
      scope = scope.where(auth_kind: "oauth_token") if %w[claude codex gemini copilot].include?(runner_key.to_s)
      scope = scope.active if require_active
      scope.order(created_at: :desc, id: :desc).first
    end

    def managed_credential_state_for(runner_key, credential)
      return :expired if credential.revoked?
      return :expired unless credential.active?

      provider = Runners::SubscriptionAuthProviders.for_runner(runner_key)
      status = provider&.status(secret: credential.token.to_s)
      return :expired if status&.expired?

      :active
    end
  end
end
