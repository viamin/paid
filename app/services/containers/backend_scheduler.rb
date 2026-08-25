# frozen_string_literal: true

module Containers
  class BackendScheduler
    Result = Struct.new(
      :candidate_hosts,
      :fallback_policy,
      :selection_source,
      :requested_host,
      :compatibility_failures,
      :health_failures,
      keyword_init: true
    ) do
      def explicit?
        selection_source == "explicit"
      end

      def fallback_enabled?
        [
          HostRegistry::FALLBACK_FIRST_HEALTHY,
          HostRegistry::FALLBACK_CAPACITY_AWARE
        ].include?(fallback_policy)
      end

      def capacity_aware?
        fallback_policy == HostRegistry::FALLBACK_CAPACITY_AWARE
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(agent_run:, registry: Containers.host_registry)
      @agent_run = agent_run
      @registry = registry
    end

    def call
      requested_host, selection_source = requested_host_and_source
      fallback_policy = selection_fallback_policy(selection_source)
      compatibility_failures = {}
      health_failures = {}
      compatibility_requirements = build_capability_requirements
      if compatibility_requirements_error
        record_requirements_failure!(
          requested_host: requested_host,
          fallback_policy: fallback_policy,
          selection_source: selection_source,
          compatibility_failures: compatibility_failures,
          error_message: compatibility_requirements_error.message
        )
      end
      candidate_hosts = if compatibility_requirements_error
        []
      else
        compatible_candidates_for(
          requested_host,
          compatibility_requirements: compatibility_requirements,
          fallback_policy: fallback_policy,
          selection_source: selection_source,
          compatibility_failures: compatibility_failures,
          health_failures: health_failures
        )
      end

      Result.new(
        candidate_hosts: candidate_hosts,
        fallback_policy: fallback_policy,
        selection_source: selection_source,
        requested_host: requested_host,
        compatibility_failures: compatibility_failures,
        health_failures: health_failures
      )
    end

    private

    attr_reader :agent_run, :registry

    def requested_host_and_source
      selection = agent_run.container_host_selection

      explicit_host = selection["explicit_host"].presence
      return [ explicit_host, "explicit" ] if explicit_host

      preferred_host = selection["preferred_host"].presence
      return [ preferred_host, "preferred" ] if preferred_host

      [ registry.default_host, "default" ]
    end

    def selection_fallback_policy(selection_source)
      return HostRegistry::FALLBACK_DISABLED if selection_source == "explicit"

      selection = agent_run.container_host_selection
      selection["fallback"].presence || registry.fallback_policy
    end

    def compatible_candidates_for(requested_host, compatibility_requirements:, fallback_policy:, selection_source:, compatibility_failures:, health_failures:)
      # @spec CONTAINER-RUNTIME-002
      candidates = [ requested_host.to_s ]
      if [
        HostRegistry::FALLBACK_FIRST_HEALTHY,
        HostRegistry::FALLBACK_CAPACITY_AWARE
      ].include?(fallback_policy) && selection_source != "explicit"
        candidates.concat(registry.fallback_candidates_for(requested_host))
      end

      # RDR-048 first_healthy contract: when fallback is disabled, only the
      # requested host is a candidate. Without fallbacks there is nothing
      # for a health check to enable/disable, so skip the ping and let the
      # selected host's Docker calls surface a reachable/unreachable error
      # later in the workflow. When fallback is enabled (or the run is
      # explicit-pinned), the ping is required — see the comment below.
      skip_health_check = fallback_policy == HostRegistry::FALLBACK_DISABLED

      candidates.filter do |host|
        # @spec EXEC-DISABLE-004
        # placement_ready_for_agent_runs (checked at run creation) is not
        # consulted here, so a backend-scoped execution control enabled
        # after the run was queued — or a run whose stored selection/default
        # never went through that scope — must be rejected at dispatch too.
        if disabled_backend_identifiers.include?(host)
          compatibility_failures[host] = "Host #{host} is disabled by an execution control"
          next false
        end

        compatibility = backend_compatibility_for(host, requirements: compatibility_requirements)
        unless compatibility[:compatible]
          compatibility_failures[host] = compatibility[:error]
          next false
        end

        # The FALLBACK_FIRST_HEALTHY contract requires filtering by Docker
        # daemon health, not just by mount/auth compatibility. Without this,
        # an unreachable preferred host is selected over a reachable
        # alternative, and a saturated preferred daemon cannot fall back.
        next true if selection_source == "explicit"
        next true if skip_health_check

        health = backend_health_for(host)
        if health.healthy?
          true
        else
          health_failures[host] = health.error_message
          false
        end
      end
    end

    def disabled_backend_identifiers
      @disabled_backend_identifiers ||= DockerHost.disabled_placement_identifiers(agent_run.project.account_id)
    end

    def backend_compatibility_for(host, requirements:)
      host_definition = registry.host(host)
      return { compatible: false, error: "Host #{host} is not configured" } unless host_definition

      compatibility = Containers::Provision.compatibility_for(
        agent_run: agent_run,
        backend: host_definition.backend,
        worktree_path: requested_worktree_path,
        requirements: requirements
      )

      return { compatible: true } if compatibility.compatible

      { compatible: false, error: compatibility.error_message }
    end

    def backend_health_for(host)
      host_definition = registry.host(host)
      # An unconfigured host is already filtered by the compatibility pass;
      # treat it as unhealthy so a stale candidate in a fallback list still
      # gets skipped without paying another ping.
      return Containers::HealthCheck::Result.new(
        backend_identifier: host.to_s,
        healthy: false,
        pinged_at: Time.current,
        error_message: "Host #{host} is not configured"
      ) unless host_definition

      Containers::HealthCheck.ping(host_definition.backend)
    end

    def requested_worktree_path
      @requested_worktree_path ||= agent_run.worktree_path.presence
    end

    def build_capability_requirements
      requested_resources = Capacity::RequestedResources.for_agent_run(agent_run)
      service_declarations = Containers::ServiceProvisioner.new.service_declarations(agent_run)

      ExecutionRunners::CapabilityRequirements.from_agent_run(
        agent_run,
        worktree_path: requested_worktree_path,
        service_declarations: service_declarations,
        requested_resources: requested_resources,
        architecture: ExecutionRunners::RunSpec.resolve_architecture(agent_run)
      )
    rescue Containers::ImageResolver::Error, Containers::RuntimeImageCatalog::Error => e
      @compatibility_requirements_error = e
      nil
    end

    def compatibility_requirements_error
      @compatibility_requirements_error
    end

    def record_requirements_failure!(requested_host:, fallback_policy:, selection_source:, compatibility_failures:, error_message:)
      fallback_candidates = if [
        HostRegistry::FALLBACK_FIRST_HEALTHY,
        HostRegistry::FALLBACK_CAPACITY_AWARE
      ].include?(fallback_policy) && selection_source != "explicit"
        registry.fallback_candidates_for(requested_host)
      else
        []
      end

      ([ requested_host.to_s ] + fallback_candidates).uniq.each do |host|
        compatibility_failures[host] = error_message
      end
    end
  end
end
