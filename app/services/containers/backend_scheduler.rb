# frozen_string_literal: true

module Containers
  class BackendScheduler
    Result = Struct.new(
      :candidate_hosts,
      :fallback_policy,
      :selection_source,
      :requested_host,
      :compatibility_failures,
      keyword_init: true
    ) do
      def explicit?
        selection_source == "explicit"
      end

      def fallback_enabled?
        fallback_policy == HostRegistry::FALLBACK_FIRST_HEALTHY
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
      candidate_hosts = compatible_candidates_for(
        requested_host,
        fallback_policy: fallback_policy,
        selection_source: selection_source,
        compatibility_failures: compatibility_failures
      )

      Result.new(
        candidate_hosts: candidate_hosts,
        fallback_policy: fallback_policy,
        selection_source: selection_source,
        requested_host: requested_host,
        compatibility_failures: compatibility_failures
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

    def compatible_candidates_for(requested_host, fallback_policy:, selection_source:, compatibility_failures:)
      candidates = [ requested_host.to_s ]
      if fallback_policy == HostRegistry::FALLBACK_FIRST_HEALTHY && selection_source != "explicit"
        candidates.concat(registry.fallback_candidates_for(requested_host))
      end

      candidates.filter do |host|
        compatibility = backend_compatibility_for(host)
        compatibility_failures[host] = compatibility[:error] unless compatibility[:compatible]
        compatibility[:compatible]
      end
    end

    def backend_compatibility_for(host)
      host_definition = registry.host(host)
      return { compatible: false, error: "Host #{host} is not configured" } unless host_definition

      compatibility = Containers::Provision.compatibility_for(
        agent_run: agent_run,
        backend: host_definition.backend,
        worktree_path: agent_run.worktree_path.presence
      )

      return { compatible: true } if compatibility.compatible

      { compatible: false, error: compatibility.error_message }
    end
  end
end
