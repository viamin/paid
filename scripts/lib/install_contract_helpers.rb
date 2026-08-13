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

    command = ensure_ignore_scripts(command)
    command = append_postinstall(command, contract) if postinstall_sensitive_contract?(contract)
    command
  end

  def postinstall_sensitive_contract?(contract)
    POSTINSTALL_SIGNAL_KEYS.any? { |key| contract[key] }
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
