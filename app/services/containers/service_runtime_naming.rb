# frozen_string_literal: true

module Containers
  # Shared naming for service-container Docker network aliases.
  #
  # Provisioning registers each service container on the agent network under
  # this alias and points the run's SERVICE_*_HOST env vars at it (see
  # Containers::ServiceProvisioner#generate_env_vars), so any consumer that
  # must record or resolve the host a container actually dials — egress policy
  # snapshots, firewall destinations, health probes — MUST derive it here
  # instead of using the user-facing ServiceContainer name, which is not
  # resolvable on the network.
  module ServiceRuntimeNaming
    RUNTIME_NAME_PREFIX = "paid-svc"
    MAX_NETWORK_ALIAS_LENGTH = 63

    module_function

    # Network alias shape: paid-svc-a<account_id>-s<id>-<sanitized-name>.
    def runtime_name(service_container)
      suffix = "a#{service_container.account_id}-s#{service_container.id}"
      budget = [ MAX_NETWORK_ALIAS_LENGTH - RUNTIME_NAME_PREFIX.length - suffix.length - 2, 1 ].max
      name = sanitized_runtime_segment(service_container.name)
      segment = name.first(budget).delete_suffix("-").presence || "service"

      [ RUNTIME_NAME_PREFIX, suffix, segment ].join("-")
    end

    def sanitized_runtime_segment(name)
      name.to_s.downcase
        .gsub(/[^a-z0-9-]/, "-")
        .gsub(/-+/, "-")
        .delete_prefix("-")
        .presence || "service"
    end
  end
end
