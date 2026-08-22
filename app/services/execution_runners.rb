# frozen_string_literal: true

require "digest"
require "json"

# ExecutionRunners defines the domain-oriented runner contract that will
# replace direct Docker API access in orchestration code (RDR-054).
#
# The contract is driven by what +Containers::Provision+ actually does today,
# not speculative generalization. It models the complete execution environment
# — primary workload, sidecars, services, network, and workspace — as a single
# lifecycle owned by a runner implementation.
#
# Intent flows: RunSpec (what to run) → runner.provision → RunnerHandle (opaque
# reference) → runner.start → ExecutionResult (outcome) → runner.cleanup.
#
# This module defines the interface value objects and the error hierarchy.
# Concrete runners subclass {ExecutionRunners::Base}.
#
# @see ExecutionRunners::Base
module ExecutionRunners
  MANIFEST_SCHEMA_VERSION = "remote_execution.v1"
  REQUIRED_OWNERSHIP_TAG_NAMES = %w[environment account project run attempt resource].freeze

  def self.json_value(value)
    case value
    when Array
      value.map { |entry| json_value(entry) }
    when Hash
      value.each_with_object({}) do |(key, entry), result|
        result[key.to_s] = json_value(entry)
      end
    else
      if value.class.name&.start_with?("ExecutionRunners::") && value.respond_to?(:to_h)
        json_value(value.to_h)
      else
        value
      end
    end
  end

  # Resolves the concrete runner for a backend/runner descriptor. All current
  # backends (local Docker, remote Docker, Swarm) are Docker transports, so
  # they all resolve to {LocalDockerRunner} today; a future non-Docker runner
  # (e.g. a remote-machine runner) adds a branch here rather than changing
  # callers (RDR-054).
  #
  # @param backend [Object] backend/runner descriptor to resolve a runner for
  # @return [Base] a runner instance
  # @spec CONTAINER-RUNTIME-010
  def self.resolve(backend:)
    LocalDockerRunner.new
  end

  # Convenience resolver that derives the backend from an agent run.
  # All current backends (local Docker, remote Docker, Swarm) are Docker
  # transports, so every agent run resolves to {LocalDockerRunner} (RDR-054).
  # @param agent_run [AgentRun] the run to resolve a runner for
  # @return [Base]
  def self.resolve_for(agent_run)
    resolve(backend: Containers.backend_for(agent_run.workspace_volume_host))
  rescue Containers::Backends::Resolver::UnknownBackendError
    resolve(backend: nil)
  end

  # Compute resource limits for a workload. Mirrors the provider-neutral
  # execution request that admission and observability reason about; Docker
  # runners only consume cpu/memory/pids directly today, while disk_bytes is
  # used by infrastructure admission and future remote runners.
  # @spec CONTAINER-RUNTIME-009
  # @spec CONTAINER-RUNTIME-027
  ComputeRequirements = Data.define(:cpu_quota, :memory_bytes, :disk_bytes, :pids_limit)

  # A writable directory inside the workload. A Docker runner translates this
  # to a tmpfs mount; a remote runner translates it to ephemeral disk or
  # platform-native writable storage. Declared on {WorkspaceStrategy} so the
  # writable layout travels with the workspace contract instead of being
  # hardcoded by orchestration code.
  #
  # The data shape and +docker_tmpfs_options+ helper exist so the runner can
  # translate the strategy's writable dirs into Docker tmpfs mounts when
  # CONTAINER-RUNTIME-012 lands; today +Containers::Provision#host_config+
  # still hardcodes its own +Tmpfs+ block.
  # @spec CONTAINER-RUNTIME-011
  # @spec CONTAINER-RUNTIME-012
  WritableDir = Data.define(:path, :size_bytes, :mode, :exec) do
    DEFAULT_MODE = 0o755

    def self.build(path, size_bytes:, mode: DEFAULT_MODE, exec: false)
      new(path: path, size_bytes: size_bytes, mode: mode, exec: exec)
    end

    # Docker tmpfs mount options string (e.g. +"exec,size=1073741824,mode=1777"+).
    # Used by the runner when it begins translating the strategy's writable
    # dirs into Provision calls (CONTAINER-RUNTIME-012).
    def docker_tmpfs_options
      parts = []
      parts << "exec" if exec
      parts << "size=#{size_bytes}"
      parts << "mode=#{format("%04o", mode)}"
      parts.join(",")
    end
  end

  # Heartbeat monitoring configuration carried by the workspace strategy. The
  # runner owns how the heartbeat path is made observable — a host bind mount
  # when the backend exposes host paths, an in-container tmpfs otherwise — so
  # callers never reach into Docker volume/tmpfs mechanics.
  #
  # Declared on the strategy as the provider-neutral shape today so callers
  # can begin expressing heartbeat needs on the strategy; the actual
  # runner-owned translation lands with CONTAINER-RUNTIME-013, after which
  # +LocalDockerRunner#start+ reads +workspace.heartbeat+ instead of taking
  # +heartbeat_path:+ directly.
  # @spec CONTAINER-RUNTIME-011
  # @spec CONTAINER-RUNTIME-013
  HeartbeatConfig = Data.define(:mount_point)

  # Provider-neutral workspace/storage strategy, isolating workspace assumptions
  # from Docker volumes and bind mounts (RDR-054). A runner implementation
  # translates the mode into its native storage primitive:
  #
  #   :named_volume    — runner-managed named volume (Docker: +paid-workspace-<id>+)
  #   :bind_mount      — an existing host path mounted into the workload (legacy worktree)
  #   :ephemeral       — ephemeral container-local storage, no persistence
  #   :object_storage  — remote object storage synced into the workload (future)
  #
  # +reference+ is nil until a runner provisions storage; afterwards it holds
  # the opaque storage reference (volume name, host path, or storage URI) that
  # {RunnerHandle#workspace_ref} carries for recovery and cleanup. Volume-name
  # construction lives inside the runner, never in orchestration or the domain
  # model.
  # @spec CONTAINER-RUNTIME-011
  WorkspaceStrategy = Data.define(:mode, :mount_point, :reference, :writable_dirs, :heartbeat) do
    DEFAULT_MOUNT_POINT = "/workspace"
    HEARTBEAT_MOUNT_POINT = "/paid-heartbeat"

    # Default writable directories every workload needs (scratch + tool cache).
    # Runner-specific credential tmpfs mounts (e.g. ~/.claude, ~/.codex) are a
    # Docker-implementation detail owned by the runner, not part of the
    # provider-neutral workspace contract.
    def self.default_writable_dirs
      [
        WritableDir.build("/tmp", size_bytes: 1024 * 1024 * 1024, mode: 0o1777, exec: true),
        WritableDir.build("/home/agent/.cache", size_bytes: 512 * 1024 * 1024, mode: 0o755, exec: true)
      ]
    end

    def self.named_volume(mount_point: DEFAULT_MOUNT_POINT,
                          writable_dirs: default_writable_dirs)
      new(mode: :named_volume, mount_point: mount_point, reference: nil,
          writable_dirs: writable_dirs, heartbeat: HeartbeatConfig.new(mount_point: HEARTBEAT_MOUNT_POINT))
    end

    def self.bind_mount(reference:, mount_point: DEFAULT_MOUNT_POINT,
                        writable_dirs: default_writable_dirs)
      new(mode: :bind_mount, mount_point: mount_point, reference: reference,
          writable_dirs: writable_dirs, heartbeat: HeartbeatConfig.new(mount_point: HEARTBEAT_MOUNT_POINT))
    end

    def self.ephemeral(mount_point: DEFAULT_MOUNT_POINT,
                       writable_dirs: default_writable_dirs)
      new(mode: :ephemeral, mount_point: mount_point, reference: nil,
          writable_dirs: writable_dirs, heartbeat: HeartbeatConfig.new(mount_point: HEARTBEAT_MOUNT_POINT))
    end

    def named_volume?
      mode == :named_volume
    end

    def bind_mount?
      mode == :bind_mount
    end
  end

  # Provider-neutral inbound exposure exception. Execution environments are
  # default-deny for public ingress; any exception must be explicit, scoped,
  # authenticated, and time-bounded.
  # @spec EXEC-INGRESS-001
  # @spec EXEC-INGRESS-002
  IngressCapability = Data.define(
    :kind,
    :scope,
    :expires_at,
    :authentication,
    :granted_at,
    :granted_by
  ) do
    SUPPORTED_KINDS = %w[preview browser debug callback].freeze
    PREVIEW_KIND = "preview".freeze
    AUTHENTICATED_AUTH_TYPES = %w[signed_token authenticated_proxy].freeze

    def self.build(kind:, scope:, expires_at:, authentication:, granted_at:, granted_by:)
      new(
        kind: kind.to_s,
        scope: scope.to_s,
        expires_at: normalize_time(expires_at),
        authentication: normalize_authentication(authentication),
        granted_at: normalize_time(granted_at),
        granted_by: granted_by.to_s
      )
    end

    def self.from_h(payload)
      data = payload.respond_to?(:to_h) ? payload.to_h : {}
      build(
        kind: data[:kind] || data["kind"],
        scope: data[:scope] || data["scope"],
        expires_at: data[:expires_at] || data["expires_at"],
        authentication: data[:authentication] || data["authentication"],
        granted_at: data[:granted_at] || data["granted_at"],
        granted_by: data[:granted_by] || data["granted_by"]
      )
    end

    def preview?
      kind == PREVIEW_KIND
    end

    def supported_kind?
      kind.in?(SUPPORTED_KINDS)
    end

    def authenticated?
      authentication.fetch("required", false) == true &&
        AUTHENTICATED_AUTH_TYPES.include?(authentication["type"])
    end

    def valid_grant?
      supported_kind? &&
        expires_at.present? &&
        expires_at.future? &&
        granted_at.present? &&
        granted_by.present? &&
        authenticated?
    end

    def to_h
      {
        "kind" => kind,
        "scope" => scope,
        "expires_at" => expires_at&.iso8601,
        "authentication" => authentication,
        "granted_at" => granted_at&.iso8601,
        "granted_by" => granted_by
      }
    end

    class << self
      private

      def normalize_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return if value.blank?

        Time.zone.parse(value.to_s)
      end

      def normalize_authentication(value)
        auth = value.respond_to?(:to_h) ? value.to_h : {}
        {
          "required" => ActiveModel::Type::Boolean.new.cast(auth[:required] || auth["required"]),
          "type" => (auth[:type] || auth["type"]).to_s
        }
      end
    end
  end

  # Provider-neutral ingress policy carried on the run contract.
  # @spec EXEC-INGRESS-001
  # @spec EXEC-INGRESS-002
  IngressPolicy = Data.define(:public_inbound, :capabilities) do
    def self.default_deny(capabilities: [])
      new(public_inbound: false, capabilities: Array(capabilities))
    end

    def self.from_metadata(metadata)
      raw = metadata.respond_to?(:to_h) ? metadata.to_h : {}
      capabilities = Array(raw[:capabilities] || raw["capabilities"]).map do |entry|
        entry.is_a?(IngressCapability) ? entry : IngressCapability.from_h(entry)
      end

      raw_public_inbound = raw[:public_inbound] || raw["public_inbound"]
      public_inbound_value = ActiveModel::Type::Boolean.new.cast(raw_public_inbound)

      new(
        public_inbound: public_inbound_value.nil? ? false : public_inbound_value,
        capabilities: capabilities
      )
    end

    def explicit?
      public_inbound == false
    end

    def preview_only?
      capabilities.all?(&:preview?)
    end

    def supported_for_runtime?
      explicit? &&
        preview_only? &&
        capabilities.all?(&:valid_grant?)
    end

    def violation_message
      return "Execution ingress policy must explicitly deny public inbound exposure." unless explicit?
      return nil if capabilities.empty?
      return nil if supported_for_runtime?

      unsupported = capabilities.reject(&:preview?).map(&:kind).uniq
      return "Unsupported inbound exposure requested: #{unsupported.join(', ')}." if unsupported.any?

      "Ingress exception grants must be authenticated, time-bounded, and explicitly recorded."
    end

    def validate_supported!
      message = violation_message
      raise ExecutionRunners::ProvisionError, message if message.present?
    end

    def to_h
      {
        "public_inbound" => public_inbound == true,
        "capabilities" => capabilities.map(&:to_h)
      }
    end
  end

  # Immutable description of what to execute. Built by orchestration from the
  # +AgentRun+/+Project+ context and handed to {ExecutionRunners::Base#provision}.
  # @spec CONTAINER-RUNTIME-009
  # @spec CONTAINER-RUNTIME-011
  # @spec IMMUTABLE-IMAGE-001
  # @spec IMMUTABLE-IMAGE-002
  # @spec IMMUTABLE-IMAGE-006
  RunSpec = Data.define(
    :agent_run,          # AgentRun context
    :project,            # Project context
    :image,              # Workload image (final resolved reference)
    :command,            # Agent command to execute
    :resources,          # ComputeRequirements (cpu, memory, pids)
    :environment,        # Hash of env vars
    :networking_policy,  # NetworkingPolicy (restricted vs. direct)
    :ingress_policy,     # IngressPolicy (default deny + scoped exceptions)
    :workspace,          # WorkspaceStrategy (named_volume | bind_mount | ephemeral)
    :services,           # Array<ServiceDeclaration>
    :secrets_config,     # Auth/credential configuration
    :runtime_image_selection # Containers::RuntimeImageSelector::Result (RDR-059)
  ) do
    # +runtime_image_selection+ defaults to nil so existing direct +.new+
    # call sites (tests constructing a RunSpec by hand) do not need to know
    # about runtime image resolution; only {.from_agent_run} populates it.
    def initialize(agent_run:, project:, image:, command:, resources:, environment:,
      networking_policy:, ingress_policy:, workspace:, services:, secrets_config:,
      runtime_image_selection: nil)
      super(
        agent_run: agent_run, project: project, image: image, command: command,
        resources: resources, environment: environment, networking_policy: networking_policy,
        ingress_policy: ingress_policy, workspace: workspace, services: services,
        secrets_config: secrets_config, runtime_image_selection: runtime_image_selection
      )
    end

    # Builds a RunSpec from an AgentRun context for the shim migration path
    # (RDR-054). Derives the workspace strategy and resource limits from the
    # agent run; the networking policy is the caller's responsibility so the
    # +NetworkingPolicy+ flows in as a domain object rather than being
    # reconstructed from Docker signals inside the runner.
    #
    # Resolves the runtime image profile/tag +options[:image]+ requests to its
    # final identity (an immutable digest in production, the mutable tag
    # elsewhere — RDR-059) and carries the full selection on +runtime_image_selection+
    # so any runner — and the {ExecutionInputManifest} handed across the
    # control-plane/runner boundary — can inspect the resolved image identity
    # without depending on the Docker-specific +Containers::Provision+
    # internals that used to be the only place this ran.
    # @param agent_run [AgentRun]
    # @param networking_policy [NetworkingPolicy, nil] required networking policy
    # @param options [Hash] container options (memory_bytes, cpu_quota, etc.)
    # @return [RunSpec]
    def self.from_agent_run(agent_run, networking_policy: nil, **options)
      workspace = workspace_strategy_for(agent_run)
      requested_resources = Capacity::RequestedResources.for_agent_run(agent_run)
      resources = ComputeRequirements.new(
        cpu_quota: positive_numeric_option(options[:cpu_quota]) || requested_resources[:cpu_quota],
        memory_bytes: positive_numeric_option(options[:memory_bytes]) || requested_resources[:memory_bytes],
        disk_bytes: positive_numeric_option(options[:disk_bytes]) || requested_resources[:disk_bytes],
        pids_limit: positive_numeric_option(options[:pids_limit]) || Containers::Provision::DEFAULTS[:pids_limit]
      )
      selection = resolve_runtime_image_selection(agent_run, requested_image: options[:image])

      new(
        agent_run: agent_run,
        project: agent_run.project,
        image: selection.image,
        command: nil, # Set at start time
        resources: resources,
        environment: agent_run.service_environment || {},
        networking_policy: networking_policy,
        workspace: workspace,
        ingress_policy: agent_run.execution_ingress_policy,
        services: [],
        secrets_config: nil,
        runtime_image_selection: selection
      )
    end

    def self.positive_numeric_option(value)
      value if value.to_i.positive?
    end

    # Resolves the run's final runtime image identity, reusing a selection
    # already recorded on the run (a Temporal retry rebuilding the same spec
    # must not risk a different digest than the one already in flight) before
    # falling back to a fresh catalog resolution. Records the resolved
    # selection on the run so historical runs show the exact digest and
    # architecture used, mirroring +Containers::Provision#resolve_runtime_image_selection+
    # (which reuses this same recorded value once the runner starts
    # provisioning, so the two never disagree).
    # @spec IMMUTABLE-IMAGE-001
    # @spec IMMUTABLE-IMAGE-002
    def self.resolve_runtime_image_selection(agent_run, requested_image: nil)
      recorded_metadata = agent_run.runtime_image_selection
      selection = if recorded_metadata.present?
        Containers::RuntimeImageSelector::Result.from_metadata(recorded_metadata)
      else
        Containers::RuntimeImageSelector.select(project: agent_run.project, requested_image: requested_image)
      end
      agent_run.record_runtime_image_selection!(selection.metadata)
      selection
    end
    private_class_method :resolve_runtime_image_selection

    # Derives the workspace strategy from the agent run: a legacy bind mount
    # when an explicit worktree path is present, otherwise the default named
    # volume (in-container clone). Volume-name construction stays inside the
    # runner; the strategy only records the mode and host reference.
    def self.workspace_strategy_for(agent_run)
      worktree_path = agent_run.worktree_path.presence
      return WorkspaceStrategy.bind_mount(reference: worktree_path) if worktree_path

      WorkspaceStrategy.named_volume
    end
    private_class_method :workspace_strategy_for

    # @spec CONTAINER-RUNTIME-018
    def input_manifest
      ExecutionInputManifest.from_run_spec(self)
    end

    # Prefers the persisted authority-grant snapshot on +agent_run+ when one
    # exists *and* it still matches the current derivation inputs. This keeps a
    # provision retry aligned with the snapshot already recorded on the run and
    # audited by operators, without ever letting the manifest disagree with
    # itself: +provision_via_runner+ (app/models/agent_run.rb) deliberately
    # re-derives +networking_policy+ fresh on retry (e.g. for subscription-auth /
    # direct-outbound recovery), and the grant set also depends on the run's
    # current service-env keys, MCP server names, and runner selection. If the
    # persisted snapshot differs from the fresh derivation, it is stale relative
    # to this attempt, so grants are re-derived from current inputs instead —
    # the persisted +agent_run.authority_grants+ column itself is left untouched
    # as the historical audit record (RDR-058).
    # @spec EXECUTION-AUTHORITY-002
    def authority_grants
      persisted = persisted_authority_grants
      fresh = AuthorityGrantSet.from_agent_run(agent_run, networking_policy: networking_policy)
      return persisted if persisted == fresh

      fresh
    end

    private

    def persisted_authority_grants
      return nil unless agent_run.authority_grants.is_a?(Hash) && agent_run.authority_grants["grants"].present?

      AuthorityGrantSet.from_json(agent_run.authority_grants)
    end
  end

  # Secret-free execution authority grant contract for a run. This is derived
  # before provisioning so runners can validate support without seeing secret
  # payloads.
  # @spec EXECUTION-AUTHORITY-002
  # @spec EXECUTION-AUTHORITY-003
  # @spec EXECUTION-AUTHORITY-004
  AuthorityGrantSet = Data.define(:schema_version, :grants) do
    SCHEMA_VERSION = 1

    def self.from_agent_run(agent_run, networking_policy:)
      new(schema_version: SCHEMA_VERSION, grants: build_grants(agent_run, networking_policy))
    end

    def as_json(*)
      {
        "schema_version" => schema_version,
        "grants" => ExecutionRunners.json_value(grants)
      }
    end

    def to_json(*args)
      as_json.to_json(*args)
    end

    def to_storage
      as_json
    end

    # The network mode recorded on the +model_provider_credentials+ grant,
    # used to detect whether a persisted snapshot still matches a freshly
    # derived +NetworkingPolicy+ (see {RunSpec#authority_grants}).
    def network_mode
      grants.find { |grant| grant["kind"] == "model_provider_credentials" }&.dig("metadata", "network_mode")
    end

    def self.from_json(payload)
      data = payload.is_a?(String) ? JSON.parse(payload) : ExecutionRunners.json_value(payload)
      new(schema_version: data["schema_version"], grants: data["grants"] || [])
    end

    def self.build_grants(agent_run, networking_policy)
      delivery = provider_delivery_for(networking_policy)
      grants = [
        grant("paid_api_proxy_token", delivery: "run_proxy_token", scope: "run"),
        grant("github_authority", delivery: "control_plane_proxy", scope: "project"),
        grant("model_provider_credentials", delivery: delivery, scope: "runner",
              metadata: { "runner_key" => runner_key_for(agent_run), "network_mode" => networking_policy&.mode.to_s })
      ]

      if delivery == "subscription_auth"
        grants << grant("subscription_auth_material", delivery: "materialized_runtime_auth", scope: "runner",
                        metadata: { "runner_key" => runner_key_for(agent_run) })
      end

      mcp_server_names = mcp_server_names_for(agent_run)
      if mcp_server_names.any?
        grants << grant("mcp_credentials", delivery: "mcp_server_configuration", scope: "project",
                        metadata: { "server_names" => mcp_server_names })
      end

      if object_storage_upload_enabled_for?(agent_run)
        grants << grant("object_storage_upload_authority", delivery: "object_storage", scope: "account",
                        metadata: { "backend" => "s3_compatible" })
      end

      service_env_keys = service_env_keys_for(agent_run)
      if service_env_keys.any?
        grants << grant("service_credentials", delivery: "service_environment", scope: "run",
                        metadata: { "env_keys" => service_env_keys })
      end

      grants
    end

    def self.grant(kind, delivery:, scope:, metadata: {})
      {
        "kind" => kind,
        "delivery" => delivery,
        "scope" => scope,
        "metadata" => ExecutionRunners.json_value(metadata)
      }
    end
    private_class_method :grant

    def self.provider_delivery_for(networking_policy)
      case networking_policy&.mode
      when :subscription_auth then "subscription_auth"
      when :direct_outbound then "direct_outbound"
      else "proxy_mode"
      end
    end
    private_class_method :provider_delivery_for

    def self.runner_key_for(agent_run)
      agent_run.runner&.runner_key || RunnerSupport.runner_key_for_agent_type(agent_run.agent_type)
    end
    private_class_method :runner_key_for

    def self.mcp_server_names_for(agent_run)
      snapshot_names = Array(agent_run.mcp_server_snapshot).filter_map { |server| server["name"] }
      provisioned = agent_run.mcp_provisioned_servers || {}
      provisioned_names = Array(provisioned["stdio_servers"]).filter_map { |server| server["name"] } +
        Array(provisioned["url_servers"]).filter_map { |server| server["name"] }

      (snapshot_names + provisioned_names).uniq.sort
    end
    private_class_method :mcp_server_names_for

    def self.object_storage_upload_enabled_for?(agent_run)
      project = agent_run.project
      return false unless project

      ArtifactStorage.configured? && (project.screenshots_enabled? || project.verification_enabled?)
    end
    private_class_method :object_storage_upload_enabled_for?

    def self.service_env_keys_for(agent_run)
      (agent_run.service_environment || {}).to_h.keys.map(&:to_s).sort
    end
    private_class_method :service_env_keys_for
  end

  # Opaque reference to a launched environment, returned by +#provision+ and
  # accepted by +#start+, +#running?+, +#cancel+, and +#cleanup+.
  #
  # Must be JSON-serializable so it can be stored in a DB column or Temporal
  # activity result, enabling a workflow to recover and continue observing or
  # cleaning up a remotely running execution after worker restart or failover.
  # All fields are JSON-native primitives; +#to_json+ / +.from_json+ round-trip
  # the +runner_type+ symbol losslessly.
  # @spec CONTAINER-RUNTIME-008
  RunnerHandle = Data.define(:runner_type, :identifier, :host, :workspace_ref, :metadata) do
    def as_json(*)
      {
        "runner_type" => runner_type.to_s,
        "identifier" => identifier,
        "host" => host,
        "workspace_ref" => workspace_ref,
        "metadata" => metadata
      }
    end

    def to_json(*args)
      as_json.to_json(*args)
    end

    # Reconstructs a handle from a JSON string or a string-keyed Hash.
    def self.from_json(payload)
      data = payload.is_a?(String) ? JSON.parse(payload) : payload.transform_keys(&:to_s)
      new(
        runner_type: data["runner_type"]&.to_sym,
        identifier: data["identifier"],
        host: data["host"],
        workspace_ref: data["workspace_ref"],
        metadata: data["metadata"] || {}
      )
    end

    # Reconstruct a handle from a persisted record (e.g. an AgentRun with a
    # +runner_handle+ jsonb column). Returns nil when no handle is stored, so
    # callers can branch on handle presence without a separate query.
    # @param record [Object] a record responding to +#runner_handle+
    # @return [RunnerHandle, nil]
    def self.from_record(record)
      return nil unless record.respond_to?(:runner_handle)

      stored_handle = record.runner_handle
      return nil if stored_handle.blank?

      from_json(stored_handle)
    end

    # Serializes the handle to a JSON-native hash suitable for persisting in a
    # DB jsonb column. Round-trips losslessly through {.from_json} /
    # {.from_record}.
    # @return [Hash]
    def to_storage
      as_json
    end
  end

  # Provider-reported execution resource used during reconciliation. This is a
  # lower-level inventory shape than RunnerHandle: a handle is what Paid stores
  # to reconnect to a known environment, while TrackedResource is what a runner
  # reports back when asked "what do you currently have tagged for Paid?".
  TrackedResource = Data.define(
    :runner_type,
    :resource_type,
    :identifier,
    :host,
    :workspace_ref,
    :tags,
    :metadata
  )

  # Stable Paid ownership-tag set applied to every provisioned execution
  # resource so a leaked/orphaned resource can be attributed and reconciled
  # back to its Paid origin (RDR-060). A runner translates this to its native
  # provider tag mechanism (Docker labels for the Docker runner).
  #
  # The six tag names are the contract every Paid-managed execution resource
  # carries: environment, account, project, run, attempt, and resource kind.
  # @spec CONTAINER-RUNTIME-026
  OwnershipTags = Data.define(:environment, :account_id, :project_id, :run_id, :attempt, :resource_kind) do
    LABEL_PREFIX = "paid."

    # Builds the ownership tags from an agent-run context. The environment is
    # the Paid deployment identifier (caller-supplied so deployments without a
    # Rails.env concept can still attribute resources). Returns nil when no
    # resource kind is supplied, signalling the runner cannot attribute the
    # resource and must skip the ledger.
    def self.for(agent_run:, resource_kind:, environment:, attempt: 0)
      return nil if resource_kind.blank?

      project = agent_run&.project
      new(
        environment: environment.to_s,
        account_id: project&.account_id,
        project_id: project&.id,
        run_id: agent_run&.id,
        attempt: Integer(attempt || 0),
        resource_kind: resource_kind.to_s
      )
    end

    # The tags as a provider-label map (the Docker runner merges this into the
    # container/volume labels). Keys carry the shared `paid.*` prefix so a
    # reconciliation scan can list resources by label regardless of runner.
    def to_label_map
      values_by_name = {
        "environment" => environment,
        "account" => account_id,
        "project" => project_id,
        "run" => run_id,
        "attempt" => attempt,
        "resource" => resource_kind
      }

      ExecutionRunners::REQUIRED_OWNERSHIP_TAG_NAMES.to_h do |name|
        [ "#{LABEL_PREFIX}#{name}", values_by_name.fetch(name).to_s ]
      end
    end
  end

  # Provider-neutral networking policy, replacing Docker network names.
  # Adapted from +NetworkPolicy::NetworkContract+ but drops the Docker-specific
  # +network+ name and derives restriction from +mode+. A runner implementation
  # translates the coarse intent into its native controls — Docker networks
  # and in-container iptables for {LocalDockerRunner}; a future Fly or remote
  # runner maps the same intents to its own egress primitives.
  #
  # The vocabulary is deliberately coarse. The runner is the only place that
  # knows the underlying network and firewall mechanism; orchestration code
  # names intent, never implementation.
  #
  # +mode+ values (RDR-062):
  #   :no_outbound       — air-gapped; loopback + DNS only.
  #   :proxy_only        — restricted; only Paid secrets proxy + DNS.
  #   :git_plus_proxy    — restricted; adds GitHub CIDR ranges.
  #   :approved_services — restricted; adds service container IPs.
  #                         The default for API-key LLM runs.
  #   :model_direct      — unrestricted; provider CLI reaches upstream APIs.
  #   :explicit_internet — unrestricted; operator opt-in for full egress.
  #
  # The three backward-compatible constructors from before RDR-062
  # (+:proxy_restricted+, +:subscription_auth+, +:direct_outbound+) remain
  # valid and map onto the new intent vocabulary without changing behavior.
  #
  # +firewall+ (boolean) — whether the runner must apply in-container firewall
  #                          rules. Always true for the four restricted modes,
  #                          false for the two unrestricted modes.
  #
  # +allow_destinations+ — array of destination hashes ({host:, port:}) the
  #                          runner should grant in the firewall, in addition
  #                          to the secrets proxy and GitHub ranges. The runner
  #                          merges these with service container IPs (resolved
  #                          from Provision after containers start) and
  #                          preview-tunnel destinations, so the underlying
  #                          policy implementation never has to inspect Docker
  #                          network state.
  #
  # +egress_profile+ (symbol) — the per-run egress posture from RDR-055:
  #   :locked    — required destinations plus tenant-allowlisted destinations
  #                only. The runner still applies the firewall and the runner-
  #                specific enforcement translation.
  #   :research  — brokered fetch/search access through Paid (resolved by a
  #                downstream broker) plus the locked destinations. The runner
  #                still applies the firewall and may extend it for the
  #                broker endpoint. The profile is opt-in per run.
  #   :open      — broad outbound access (operator-only break-glass). Disabled
  #                for managed production by default; a runner that cannot
  #                enforce it must reject the run for production restricted
  #                flows. The profile is opt-in per run.
  #
  # The profile is carried through +RunSpec+ and surfaced in the
  # {ExecutionInputManifest}'s networking section so the runner and downstream
  # tooling can read it without any Docker-specific vocabulary. Defaults to
  # +:locked+ (the safe production default). The factories raise
  # +ArgumentError+ for any value outside the closed +EGRESS_PROFILES+ enum,
  # so typos or foreign values (e.g. a string instead of a symbol) fail at
  # construction instead of silently serializing into the manifest.
  #
  # @spec CONTAINER-RUNTIME-009
  # @spec CONTAINER-RUNTIME-017
  # @spec CONTAINER-RUNTIME-020
  # @spec CONTAINER-RUNTIME-028

  # The set of canonical intent modes and their restricted/unrestricted
  # classification. Defined on the module so callers and the {NetworkingPolicy}
  # value object can reference them as ordinary Ruby constants (Data.define
  # does not expose constants defined inside the block as accessible
  # attributes on the resulting class).
  NETWORKING_POLICY_RESTRICTED_MODES = [ :proxy_restricted, :no_outbound, :proxy_only, :git_plus_proxy, :approved_services ].freeze
  NETWORKING_POLICY_UNRESTRICTED_MODES = [ :subscription_auth, :direct_outbound, :model_direct, :explicit_internet ].freeze
  NETWORKING_POLICY_KNOWN_MODES = (NETWORKING_POLICY_RESTRICTED_MODES + NETWORKING_POLICY_UNRESTRICTED_MODES).freeze

  NetworkingPolicy = Data.define(:mode, :firewall, :allow_destinations, :egress_profile) do
    RESTRICTED_MODES = ExecutionRunners::NETWORKING_POLICY_RESTRICTED_MODES
    UNRESTRICTED_MODES = ExecutionRunners::NETWORKING_POLICY_UNRESTRICTED_MODES
    KNOWN_MODES = ExecutionRunners::NETWORKING_POLICY_KNOWN_MODES
    ALLOW_DESTINATION_REQUIRED_KEYS = %i[host port].freeze
    ALLOW_DESTINATION_HOST_PATTERN = /\A[a-zA-Z0-9.\-]+\z/
    LOCKED_PROFILE = :locked
    RESEARCH_PROFILE = :research
    OPEN_PROFILE = :open
    EGRESS_PROFILES = [ LOCKED_PROFILE, RESEARCH_PROFILE, OPEN_PROFILE ].freeze

    def initialize(mode:, firewall:, allow_destinations:, egress_profile: LOCKED_PROFILE)
      normalized_mode = mode&.to_sym
      normalized_destinations = normalize_allow_destinations(Array(allow_destinations))

      validate_mode!(normalized_mode)
      validate_firewall!(normalized_mode, firewall)
      validate_allow_destinations!(normalized_destinations)

      super(
        mode: normalized_mode,
        firewall: firewall,
        allow_destinations: normalized_destinations,
        egress_profile: self.class.validate_egress_profile!(egress_profile)
      )
    end

    def self.no_outbound(allow_destinations: [], egress_profile: LOCKED_PROFILE)
      new(mode: :no_outbound, firewall: true, allow_destinations: allow_destinations, egress_profile: egress_profile)
    end

    def self.proxy_only(allow_destinations: [], egress_profile: LOCKED_PROFILE)
      new(mode: :proxy_only, firewall: true, allow_destinations: allow_destinations, egress_profile: egress_profile)
    end

    def self.git_plus_proxy(allow_destinations: [], egress_profile: LOCKED_PROFILE)
      new(mode: :git_plus_proxy, firewall: true, allow_destinations: allow_destinations, egress_profile: egress_profile)
    end

    def self.approved_services(allow_destinations: [], egress_profile: LOCKED_PROFILE)
      new(mode: :approved_services, firewall: true, allow_destinations: allow_destinations, egress_profile: egress_profile)
    end

    # Backward-compatible alias for {.approved_services}. Keeps +mode+ set to
    # the legacy +:proxy_restricted+ symbol (rather than delegating to
    # {.approved_services}) so existing callers checking
    # +policy.mode == :proxy_restricted+ see no change in behavior;
    # {#canonical_mode} performs the normalization instead.
    def self.proxy_restricted(allow_destinations: [], egress_profile: LOCKED_PROFILE)
      new(mode: :proxy_restricted, firewall: true, allow_destinations: allow_destinations, egress_profile: egress_profile)
    end

    def self.model_direct(allow_destinations: [], egress_profile: LOCKED_PROFILE)
      new(mode: :model_direct, firewall: false, allow_destinations: allow_destinations, egress_profile: egress_profile)
    end

    # Backward-compatible alias for {.model_direct}. Keeps +mode+ set to the
    # legacy +:subscription_auth+ symbol so {#canonical_mode} normalizes it
    # rather than the constructor silently swapping the mode.
    def self.subscription_auth(egress_profile: LOCKED_PROFILE)
      new(mode: :subscription_auth, firewall: false, allow_destinations: [], egress_profile: egress_profile)
    end

    # Backward-compatible alias for {.model_direct}. Keeps +mode+ set to the
    # legacy +:direct_outbound+ symbol so {#canonical_mode} normalizes it.
    def self.direct_outbound(egress_profile: LOCKED_PROFILE)
      new(mode: :direct_outbound, firewall: false, allow_destinations: [], egress_profile: egress_profile)
    end

    def self.explicit_internet(egress_profile: LOCKED_PROFILE)
      new(mode: :explicit_internet, firewall: false, allow_destinations: [], egress_profile: egress_profile)
    end

    # Validates that +egress_profile+ is one of the closed RDR-055 enum
    # values. Shared by every construction path, including direct +.new+ and
    # +#with+, so invalid values fail before they can silently serialize into
    # the runner manifest.
    def self.validate_egress_profile!(egress_profile)
      unless EGRESS_PROFILES.include?(egress_profile)
        raise ArgumentError, "Invalid egress_profile: #{egress_profile.inspect}"
      end

      egress_profile
    end

    def with(**kwargs)
      super.tap { |updated| self.class.validate_egress_profile!(updated.egress_profile) }
    end

    def restricted?
      RESTRICTED_MODES.include?(mode)
    end

    def firewall?
      firewall
    end

    # +true+ when the intent names a provider-direct outbound run (subscription
    # auth or direct outbound). Distinguishes the two unrestricted intents.
    def model_direct?
      mode == :model_direct || mode == :subscription_auth || mode == :direct_outbound
    end

    # +true+ when the intent names an explicit-internet run (operator opt-in
    # full egress). Distinguishes the two unrestricted intents.
    def explicit_internet?
      mode == :explicit_internet
    end

    # +true+ when the policy is meant to block all outbound traffic.
    # Runners with iptables + a default-deny script can implement this; runners
    # without a firewall capability reject it via {.supports_policy?}.
    def no_outbound?
      mode == :no_outbound
    end

    # +true+ when the intent includes service container IPs in its allowlist.
    # Only the approved-services intent (and its +:proxy_restricted+ alias)
    # grants service containers; the narrower restricted intents do not
    # (RDR-062 mapping table).
    def approved_services?
      canonical_mode == :approved_services
    end

    # Returns the canonical intent mode. The three backward-compatible modes
    # (:proxy_restricted, :subscription_auth, :direct_outbound) are normalized
    # to their new-intent names so downstream translation paths only see the
    # canonical six-intent set.
    def canonical_mode
      case mode
      when :proxy_restricted then :approved_services
      when :subscription_auth, :direct_outbound then :model_direct
      else mode
      end
    end

    def locked?
      egress_profile == LOCKED_PROFILE
    end

    def research?
      egress_profile == RESEARCH_PROFILE
    end

    def open?
      egress_profile == OPEN_PROFILE
    end

    private

    def validate_mode!(mode)
      return if KNOWN_MODES.include?(mode)

      raise ArgumentError, "Unknown networking policy mode: #{mode.inspect}"
    end

    def validate_firewall!(mode, firewall)
      expected_firewall = RESTRICTED_MODES.include?(mode)
      return if firewall == expected_firewall

      raise ArgumentError, "Networking policy #{mode.inspect} requires firewall=#{expected_firewall}"
    end

    def validate_allow_destinations!(destinations)
      destinations.each do |destination|
        unless destination.is_a?(Hash)
          raise ArgumentError, "Allow destinations must be hashes with :host and :port"
        end

        missing_keys = ALLOW_DESTINATION_REQUIRED_KEYS.reject { |key| destination[key].present? }
        next if missing_keys.empty?

        raise ArgumentError, "Allow destination is missing keys: #{missing_keys.join(', ')}"
      end

      destinations.each do |destination|
        validate_allow_destination_host!(destination[:host])
        validate_allow_destination_port!(destination[:port])
      end
    end

    def normalize_allow_destinations(destinations)
      destinations.map do |destination|
        next destination unless destination.is_a?(Hash)

        {
          host: destination[:host] || destination["host"],
          port: normalize_allow_destination_port(destination[:port] || destination["port"])
        }
      end
    end

    def validate_allow_destination_host!(host)
      return if host.is_a?(String) && host.match?(ALLOW_DESTINATION_HOST_PATTERN)

      raise ArgumentError, "Allow destination host is invalid: #{host.inspect}"
    end

    def validate_allow_destination_port!(port)
      return if port.is_a?(Integer) && port.between?(1, 65_535)

      raise ArgumentError, "Allow destination port is invalid: #{port.inspect}"
    end

    def normalize_allow_destination_port(port)
      Integer(port)
    rescue ArgumentError, TypeError
      port
    end
  end

  # Provider-neutral service declaration, replacing Docker-specific service
  # provisioning. A runner translates this to the native sidecar/process model.
  #
  # +type+ values: :database | :cache | :browser | :mcp_sidecar | :custom
  # @spec CONTAINER-RUNTIME-009
  ServiceDeclaration = Data.define(:name, :image, :port, :env, :type)

  # Provider-neutral manifest that crosses the control-plane/runner boundary
  # before execution starts. It carries only references and declarative spec
  # data: repo/ref, execution settings, prompt/context references, services,
  # and the four transfer lanes (git, control-plane API, object storage,
  # credentials). Secret values are excluded by construction — credential lane
  # entries only name sources/keys, never values.
  # @spec CONTAINER-RUNTIME-018
  # @spec IMMUTABLE-IMAGE-006
  ExecutionInputManifest = Data.define(
    :schema_version,
    :repository,
    :execution,
    :prompt_refs,
    :context_refs,
    :services,
    :artifact_refs,
    :lanes
  ) do
    def self.from_run_spec(spec)
      agent_run = spec.agent_run
      project = spec.project
      prompt_refs = build_prompt_refs(agent_run)
      context_refs = build_context_refs(agent_run)

      new(
        schema_version: MANIFEST_SCHEMA_VERSION,
        repository: {
          "provider" => "github",
          "repo_full_name" => project&.full_name,
          "repository_url" => project&.github_url,
          "ref" => {
            "branch_name" => agent_run&.branch_name,
            "base_commit_sha" => agent_run&.base_commit_sha,
            "source_pull_request_number" => agent_run&.source_pull_request_number
          }.compact
        }.compact,
        execution: {
          "agent_run_id" => agent_run&.id,
          "goal" => agent_run&.goal,
          "execution_origin" => agent_run&.execution_origin,
          "image" => spec.image,
          "runtime_image" => spec.runtime_image_selection&.metadata,
          "command" => spec.command,
          "resources" => ExecutionRunners.json_value(spec.resources&.to_h || {}),
          "workspace" => {
            "mode" => spec.workspace&.mode&.to_s,
            "mount_point" => spec.workspace&.mount_point
          }.compact,
          "ingress" => {
            "public_inbound" => spec.ingress_policy&.public_inbound == true,
            "capabilities" => ExecutionRunners.json_value(spec.ingress_policy&.capabilities&.map(&:to_h) || [])
          }.compact,
          "networking" => {
            "mode" => spec.networking_policy&.canonical_mode&.to_s,
            "firewall" => spec.networking_policy&.firewall?,
            "allow_destinations" => ExecutionRunners.json_value(spec.networking_policy&.allow_destinations || []),
            "egress_profile" => spec.networking_policy&.egress_profile&.to_s
          }.compact,
          "authority_grants" => spec.authority_grants.as_json
        }.compact,
        prompt_refs: prompt_refs,
        context_refs: context_refs,
        services: build_services(spec.services),
        artifact_refs: [],
        lanes: {
          "git" => build_git_lane(project, agent_run),
          "control_plane_api" => prompt_refs + context_refs,
          "object_storage" => [],
          "credentials" => build_credential_lane(spec)
        }
      )
    end

    def as_json(*)
      {
        "schema_version" => schema_version,
        "repository" => ExecutionRunners.json_value(repository),
        "execution" => ExecutionRunners.json_value(execution),
        "prompt_refs" => ExecutionRunners.json_value(prompt_refs),
        "context_refs" => ExecutionRunners.json_value(context_refs),
        "services" => ExecutionRunners.json_value(services),
        "artifact_refs" => ExecutionRunners.json_value(artifact_refs),
        "lanes" => ExecutionRunners.json_value(lanes)
      }
    end

    def to_json(*args)
      as_json.to_json(*args)
    end

    def self.from_json(payload)
      data = payload.is_a?(String) ? JSON.parse(payload) : ExecutionRunners.json_value(payload)

      new(
        schema_version: data["schema_version"],
        repository: data["repository"] || {},
        execution: data["execution"] || {},
        prompt_refs: data["prompt_refs"] || [],
        context_refs: data["context_refs"] || [],
        services: data["services"] || [],
        artifact_refs: data["artifact_refs"] || [],
        lanes: data["lanes"] || {}
      )
    end

    def self.build_prompt_refs(agent_run)
      refs = []
      if agent_run&.prompt_version_id.present?
        refs << {
          "lane" => "control_plane_api",
          "kind" => "prompt_version",
          "locator" => { "prompt_version_id" => agent_run.prompt_version_id }
        }
      end
      if agent_run&.custom_prompt.present?
        refs << {
          "lane" => "control_plane_api",
          "kind" => "custom_prompt",
          "locator" => {
            "agent_run_id" => agent_run.id,
            "sha256" => Digest::SHA256.hexdigest(agent_run.custom_prompt)
          }
        }
      end
      refs
    end

    def self.build_context_refs(agent_run)
      refs = []
      if agent_run&.issue_id.present?
        refs << {
          "lane" => "control_plane_api",
          "kind" => "issue",
          "locator" => { "issue_id" => agent_run.issue_id }
        }
      end
      refs
    end

    def self.build_services(services)
      Array(services).map do |service|
        {
          "name" => service.name,
          "image" => service.image,
          "port" => service.port,
          "type" => service.type&.to_s,
          "env_keys" => Array(service.env).map(&:first).map(&:to_s).sort
        }.compact
      end
    end

    def self.build_git_lane(project, agent_run)
      [
        {
          "lane" => "git",
          "kind" => "repository_checkout",
          "locator" => {
            "repo_full_name" => project&.full_name,
            "branch_name" => agent_run&.branch_name,
            "base_commit_sha" => agent_run&.base_commit_sha,
            "source_pull_request_number" => agent_run&.source_pull_request_number
          }.compact
        }
      ]
    end

    def self.build_credential_lane(spec)
      env_refs = Array(spec.environment).map do |key, _value|
        {
          "lane" => "credentials",
          "kind" => "environment_variable",
          "locator" => { "name" => key.to_s },
          "source" => "run_spec.environment"
        }
      end
      service_refs = Array(spec.services).flat_map do |service|
        Array(service.env).map do |key, _value|
          {
            "lane" => "credentials",
            "kind" => "service_environment_variable",
            "locator" => { "name" => key.to_s, "service" => service.name },
            "source" => "service_declaration.env"
          }
        end
      end
      secret_config_refs = Array(spec.secrets_config).map do |key, _value|
        {
          "lane" => "credentials",
          "kind" => "secrets_config_entry",
          "locator" => { "name" => key.to_s },
          "source" => "run_spec.secrets_config"
        }
      end

      (env_refs + service_refs + secret_config_refs).uniq
    end
  end

  # Result of {ExecutionRunners::Base.compatible?}. Mirrors the shape of
  # +Containers::Provision::CompatibilityResult+ but lives in the
  # provider-neutral namespace so the abstract interface never references a
  # Docker-specific class.
  # @spec CONTAINER-RUNTIME-007
  CompatibilityResult = Data.define(:compatible, :error_message)

  # Outcome of running a workload. Consolidates the existing
  # +Containers::Provision::Result+ patterns so callers no longer reach into
  # the Docker result object.
  # @spec CONTAINER-RUNTIME-009
  ExecutionResult = Data.define(
    :success,             # Boolean
    :stdout,              # String
    :stderr,              # String
    :exit_code,           # Integer
    :oom_killed,          # Boolean
    :memory_limit_bytes,  # Integer, nil
    :environment_running  # Boolean, nil — whether the launched environment is
    # still running after the workload exited (used for OOM diagnostics)
  ) do
    def success?
      success
    end

    def failure?
      !success
    end

    def self.success(stdout: "", stderr: "", exit_code: 0)
      new(success: true, stdout: stdout, stderr: stderr, exit_code: exit_code,
          oom_killed: false, memory_limit_bytes: nil, environment_running: nil)
    end

    def self.failure(exit_code:, stdout: "", stderr: "",
                     oom_killed: false, memory_limit_bytes: nil, environment_running: nil)
      new(success: false, stdout: stdout, stderr: stderr, exit_code: exit_code,
          oom_killed: oom_killed, memory_limit_bytes: memory_limit_bytes,
          environment_running: environment_running)
    end

    # @spec CONTAINER-RUNTIME-018
    def output_manifest(agent_run:, binary_artifacts: nil, structured_results: nil, log_refs: nil)
      ExecutionOutputManifest.from_result(
        execution_result: self,
        agent_run: agent_run,
        binary_artifacts: binary_artifacts,
        structured_results: structured_results,
        log_refs: log_refs
      )
    end
  end

  # Provider-neutral manifest emitted after execution completes. It separates
  # code outputs (git identity), durable binary artifacts (object-storage refs),
  # and structured results (verification payloads, summaries) while keeping log
  # access as references. Credential values are never emitted in outputs.
  # @spec CONTAINER-RUNTIME-018
  ExecutionOutputManifest = Data.define(
    :schema_version,
    :execution,
    :result_summary,
    :artifacts,
    :log_refs,
    :verification,
    :git_output,
    :lanes
  ) do
    def self.from_result(execution_result:, agent_run:, binary_artifacts: nil, structured_results: nil, log_refs: nil)
      binary_refs = binary_artifacts || build_binary_artifact_refs(agent_run)
      verification = ExecutionRunners.json_value(agent_run.verification_result.presence || {})
      git_output = {
        "repo_full_name" => agent_run.project&.full_name,
        "branch_name" => agent_run.branch_name,
        "result_commit_sha" => agent_run.result_commit_sha,
        "pull_request_number" => agent_run.pull_request_number,
        "pull_request_url" => agent_run.pull_request_url,
        "review_url" => agent_run.review_url
      }.compact
      output_log_refs = log_refs || default_log_refs(agent_run)
      structured = structured_results || build_structured_results(verification)

      new(
        schema_version: MANIFEST_SCHEMA_VERSION,
        execution: {
          "agent_run_id" => agent_run.id,
          "status" => agent_run.status,
          "goal" => agent_run.goal,
          "execution_origin" => agent_run.execution_origin
        }.compact,
        result_summary: {
          "success" => execution_result.success?,
          "exit_code" => execution_result.exit_code,
          "oom_killed" => execution_result.oom_killed,
          "environment_running" => execution_result.environment_running,
          "stdout_bytes" => execution_result.stdout.to_s.bytesize,
          "stderr_bytes" => execution_result.stderr.to_s.bytesize
        },
        artifacts: {
          "code_outputs" => git_output.present? ? [ git_output ] : [],
          "binary_artifacts" => binary_refs,
          "structured_results" => structured
        },
        log_refs: output_log_refs,
        verification: verification,
        git_output: git_output,
        lanes: {
          "git" => git_output.present? ? [ { "lane" => "git", "kind" => "git_output", "locator" => git_output } ] : [],
          "control_plane_api" => output_log_refs + build_verification_refs(agent_run, verification),
          "object_storage" => binary_refs,
          "credentials" => []
        }
      )
    end

    def as_json(*)
      {
        "schema_version" => schema_version,
        "execution" => ExecutionRunners.json_value(execution),
        "result_summary" => ExecutionRunners.json_value(result_summary),
        "artifacts" => ExecutionRunners.json_value(artifacts),
        "log_refs" => ExecutionRunners.json_value(log_refs),
        "verification" => ExecutionRunners.json_value(verification),
        "git_output" => ExecutionRunners.json_value(git_output),
        "lanes" => ExecutionRunners.json_value(lanes)
      }
    end

    def to_json(*args)
      as_json.to_json(*args)
    end

    def self.from_json(payload)
      data = payload.is_a?(String) ? JSON.parse(payload) : ExecutionRunners.json_value(payload)

      new(
        schema_version: data["schema_version"],
        execution: data["execution"] || {},
        result_summary: data["result_summary"] || {},
        artifacts: data["artifacts"] || {},
        log_refs: data["log_refs"] || [],
        verification: data["verification"] || {},
        git_output: data["git_output"] || {},
        lanes: data["lanes"] || {}
      )
    end

    # Binary artifact references for the output manifest.
    #
    # Two source lanes feed this list:
    #
    # 1. `external_metadata["artifact_manifest"]` — usually persisted by the
    #    runner, but not exclusively: interop callers can persist arbitrary
    #    `external_metadata` (`Api::Projects::ExternalAgentRunsController` →
    #    `AgentRuns::IngestExternal` stores it verbatim). Locator keys are
    #    therefore honored only under the project's own storage namespace
    #    (`Screenshots::Storage.namespace_prefix`); any other key degrades to
    #    URL-only, so durable consumers can re-sign keys only within the
    #    run's own tenant namespace.
    # 2. `verification_result["artifacts"]` — written by the agent inside the
    #    container (`AgentRuns::VerificationResultRecorder` persists it as-is),
    #    so it is untrusted input. A spoofed key under another tenant's prefix
    #    would otherwise be re-signed into a working presigned URL, so this
    #    lane stays URL-only: only `url` (and `locator.url`) survive.
    # @spec CONTAINER-RUNTIME-018
    def self.build_binary_artifact_refs(agent_run)
      manifest_artifacts = Array(agent_run.external_metadata["artifact_manifest"])
      verification_artifacts = Array(agent_run.verification_result["artifacts"])

      manifest_refs = manifest_artifacts.filter_map do |artifact|
        normalize_binary_artifact_ref(artifact, agent_run: agent_run, trusted_key: true)
      end
      verification_refs = verification_artifacts.filter_map do |artifact|
        normalize_binary_artifact_ref(artifact, agent_run: agent_run, trusted_key: false)
      end

      manifest_refs + verification_refs
    end

    # @spec CONTAINER-RUNTIME-018
    def self.normalize_binary_artifact_ref(artifact, agent_run:, trusted_key:)
      return unless artifact.is_a?(Hash)

      normalized = artifact.deep_stringify_keys
      locator = normalized_locator(normalized, agent_run: agent_run, trusted_key: trusted_key)
      return if locator.blank?

      {
        "lane" => "object_storage",
        "kind" => normalized["kind"].presence || "artifact",
        "content_type" => normalized["content_type"].presence,
        "locator" => locator,
        "context" => normalized_context(normalized, agent_run: agent_run),
        "metadata" => normalized_metadata(normalized)
      }.compact
    end

    # @spec CONTAINER-RUNTIME-018
    def self.normalized_locator(artifact, agent_run:, trusted_key:)
      raw_locator = if artifact["locator"].is_a?(Hash)
        artifact["locator"].deep_stringify_keys.slice("key", "url")
      else
        {
          "key" => artifact["storage_key"].presence,
          "url" => artifact["url"].presence
        }
      end

      locator = trusted_key ? raw_locator : raw_locator.slice("url")
      locator = locator.slice("url") unless key_within_project_namespace?(locator["key"], agent_run)
      locator.compact.presence
    end

    # A locator key survives only under the run's own project storage
    # namespace: durable consumers re-sign keys into presigned URLs, so a key
    # planted under another tenant's prefix must degrade to URL-only — on the
    # trusted lane too, because interop ingestion can persist caller-supplied
    # `external_metadata` verbatim.
    # @spec CONTAINER-RUNTIME-018
    def self.key_within_project_namespace?(key, agent_run)
      return true if key.blank?
      return false unless key.is_a?(String)

      prefix = project_namespace_prefix(agent_run)
      prefix.present? && key.start_with?(prefix)
    end

    def self.project_namespace_prefix(agent_run)
      project = agent_run.project
      return unless project&.owner.present? && project&.repo.present?

      Screenshots::Storage.namespace_prefix(org: project.owner, repo: project.repo)
    end

    # @spec CONTAINER-RUNTIME-018
    def self.normalized_context(artifact, agent_run:)
      artifact_context = if artifact["context"].is_a?(Hash)
        artifact["context"].deep_stringify_keys.slice("account_id", "project_id", "agent_run_id")
      else
        {}
      end

      # Run identity is authoritative: the system already knows the real
      # account/project/run, so an artifact-supplied value can never override
      # it. Supplied values only survive where the run itself can't answer.
      run_context = {
        "account_id" => agent_run.project&.account_id,
        "project_id" => agent_run.project_id,
        "agent_run_id" => agent_run.id
      }.compact

      artifact_context.merge(run_context).compact.presence
    end

    def self.normalized_metadata(artifact)
      raw_metadata = artifact["metadata"]
      metadata = raw_metadata.is_a?(Hash) ? raw_metadata.deep_stringify_keys : {}
      metadata["note"] ||= artifact["note"].presence
      metadata["path"] ||= artifact["path"].presence
      metadata.compact.presence
    end

    def self.build_structured_results(verification)
      return [] if verification.blank?

      [
        {
          "kind" => "verification_result",
          "value" => verification
        }
      ]
    end

    def self.default_log_refs(agent_run)
      [
        {
          "lane" => "control_plane_api",
          "kind" => "agent_run_logs",
          "locator" => { "agent_run_id" => agent_run.id }
        }
      ]
    end

    def self.build_verification_refs(agent_run, verification)
      return [] if verification.blank?

      [
        {
          "lane" => "control_plane_api",
          "kind" => "verification_result",
          "locator" => { "agent_run_id" => agent_run.id }
        }
      ]
    end
  end

  # Result of a status query ({ExecutionRunners::Base#status}). Reports the
  # workload's lifecycle state without reaching into Docker API response
  # shapes: a future remote runner maps its platform-native liveness signal
  # to the same states. `:not_found` covers an environment that can no longer
  # be reconnected to (container gone, machine stopped, job record missing).
  #
  # +state+ values:
  #   :running     — workload still executing
  #   :exited      — workload completed (normally or with an exit code)
  #   :oom_killed  — workload was killed by the cgroup/OS OOM killer
  #   :not_found   — environment is gone and cannot be inspected
  # @spec CONTAINER-RUNTIME-015
  ExecutionStatus = Data.define(
    :state,        # :running | :exited | :oom_killed | :not_found
    :exit_code,    # Integer or nil (nil while still running or not_found)
    :oom_killed,   # Boolean — whether the workload was OOM-killed
    :memory_limit  # Integer (bytes) or nil
  ) do
    def running?
      state == :running
    end

    def exited?
      state == :exited
    end

    def oom_killed?
      state == :oom_killed
    end

    def not_found?
      state == :not_found
    end

    # Status for an environment that can no longer be inspected.
    def self.not_found
      new(state: :not_found, exit_code: nil, oom_killed: false, memory_limit: nil)
    end
  end

  # Base error for all execution-runner errors.
  class Error < StandardError; end

  # Raised when provisioning the execution environment fails.
  class ProvisionError < Error
    def initialize(msg = "Failed to provision execution environment")
      super
    end
  end

  # Raised when a workload command fails to execute.
  class ExecutionError < Error
    attr_reader :exit_code, :stdout, :stderr

    def initialize(msg, exit_code: nil, stdout: nil, stderr: nil)
      @exit_code = exit_code
      @stdout = stdout
      @stderr = stderr
      super(msg)
    end
  end

  # Raised when an operation exceeds its time budget.
  class TimeoutError < Error
    attr_reader :diagnostics

    def initialize(msg = "Operation timed out", diagnostics: {})
      @diagnostics = diagnostics
      super(msg)
    end
  end

  # Raised when no output is received within the startup timeout.
  class StartupTimeoutError < TimeoutError
    def initialize(msg = "No output received within startup timeout", diagnostics: {})
      super(msg, diagnostics: diagnostics)
    end
  end

  # Raised when output stops flowing for longer than the idle timeout.
  class IdleTimeoutError < TimeoutError
    def initialize(msg = "No output received within idle timeout", diagnostics: {})
      super(msg, diagnostics: diagnostics)
    end
  end

  # Raised when streaming output matches an abort pattern (or a structured
  # streaming failure event) indicating a fatal runner error where the CLI is
  # known to hang instead of exiting.
  #
  # +source+ distinguishes abort origins:
  #   :pattern          — stderr/stdout matched a configured quota/rate-limit pattern
  #   :streaming_event  — a CLI streaming JSONL error/turn.failed event
  class OutputAbortError < Error
    attr_reader :matched_output, :source, :detail

    def initialize(msg = "Process aborted due to fatal output pattern",
                   matched_output: nil, source: :pattern, detail: nil)
      @matched_output = matched_output
      @source = source.to_sym
      @detail = detail
      super(msg)
    end
  end
end
