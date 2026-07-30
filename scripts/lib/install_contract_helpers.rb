# frozen_string_literal: true

module InstallContractHelpers
  POSTINSTALL_SIGNAL_KEYS = %i[
    allow_postinstall
    postinstall
    postinstall_command
    postinstall_required
    requires_postinstall
    trusted_postinstall
  ].freeze

  # TEMPORARY: agent-harness 0.31.0 pins opencode-ai to 1.3.2, which predates
  # z.ai/glm support (no zai-coding-plan provider, no glm-5.x models in its
  # catalog). Auto-upgrade opencode to this floor until agent-harness ships a
  # contract pin whose version satisfies >= 1.18. The auto path only ever
  # UPGRADES (never downgrades), so once the upstream contract reaches the
  # floor this becomes a no-op and cannot silently pin opencode to a stale
  # version after agent-harness#316 lands. Override per-build with
  # OPENCODE_VERSION_OVERRIDE: set to "" to opt out, or to a specific version
  # to force it (explicit overrides are authoritative, even if older). Remove
  # this fallback (and the apply_opencode_version_override call) once the
  # upstream contract is bumped. See viamin/agent-harness#316.
  OPENCODE_VERSION_FALLBACK = "1.18.10"

  module_function

  def contract_for(provider_key)
    AgentHarness.install_contract(provider_key.to_sym)
  rescue AgentHarness::ConfigurationError
    metadata_installation_for(provider_key)
  end

  def metadata_installation_for(provider_key)
    metadata = AgentHarness.provider_metadata(provider_key.to_sym)
    installation = metadata.dig(:runtime, :installation)
    return normalize_metadata_installation(installation) if installation

    raise AgentHarness::ConfigurationError, "Provider #{provider_key} does not expose install metadata"
  end

  def normalize_metadata_installation(installation)
    source = installation[:source_type]
    contract = installation.dup
    contract[:source] ||= source if source
    contract[:package] ||= installation[:package_name] if installation[:package_name]
    contract[:version] ||= installation[:resolved_version] || installation[:default_version]
    contract[:default_version] ||= installation[:default_version] || installation[:resolved_version]
    contract[:install_command] ||= installation[:install_command]
    contract
  end

  def normalized_install_command(contract)
    command = Array(contract[:install_command]).dup
    return command if command.empty?

    command =
      if postinstall_sensitive_contract?(contract)
        append_postinstall(ensure_ignore_scripts(command), contract)
      else
        fallback_command = opencode_fallback_install_command(contract)
        fallback_command != command ? ensure_ignore_scripts(fallback_command) : ensure_ignore_scripts(command)
      end

    apply_opencode_version_override(contract, command)
  end

  def apply_opencode_version_override(contract, command)
    return command unless npm_package_name(contract) == "opencode-ai"

    # An explicit OPENCODE_VERSION_OVERRIDE is authoritative: "" opts out (use
    # the contract version as-is); any other value forces that version even if
    # it is older than the contract (intentional pin for testing).
    explicit = ENV["OPENCODE_VERSION_OVERRIDE"]
    return command if explicit == ""

    target =
      if explicit
        explicit.to_s
      else
        contract_version = (contract[:version] || contract[:default_version]).to_s
        # Auto-upgrade only: once the upstream contract reaches the floor this
        # becomes a no-op so it can never silently downgrade a future opencode.
        return command if version_gte?(contract_version, OPENCODE_VERSION_FALLBACK)
        OPENCODE_VERSION_FALLBACK
      end

    command.map { |part| part.sub(/opencode-ai@[\d.]+/, "opencode-ai@#{target}") }
  end

  def version_gte?(version, floor)
    return false if version.to_s.empty?
    Gem::Version.new(version) >= Gem::Version.new(floor)
  rescue ArgumentError
    # Unparseable version: treat as below the floor so the safe upgrade applies.
    false
  end

  def postinstall_sensitive_contract?(contract)
    POSTINSTALL_SIGNAL_KEYS.any? { |key| contract[key] }
  end

  def npm_package_name(contract)
    contract[:package_name] || contract[:package] || contract.dig(:source, :package)
  end

  def opencode_fallback_install_command(contract)
    command = Array(contract[:install_command]).dup
    return command unless npm_package_name(contract) == "opencode-ai"

    # agent-harness 0.18.2 still models OpenCode as a plain npm install even
    # though the package needs a trusted postinstall step to extract its native
    # binary. Keep the hardening default for dependencies, then run the single
    # allowlisted postinstall explicitly until the upstream contract is released.
    command + [ "&&", "node", "$(npm root -g)/opencode-ai/postinstall.mjs" ]
  end

  def append_postinstall(command, contract)
    postinstall = contract[:postinstall_command]
    return command unless postinstall

    command + [ "&&", *postinstall.split(" ") ]
  end

  def ensure_ignore_scripts(command)
    return command if command.include?("--ignore-scripts")

    insertion_index = command.index("&&") || command.length
    command.dup.insert(insertion_index, "--ignore-scripts")
  end
end
