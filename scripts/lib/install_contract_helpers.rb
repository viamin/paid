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

  def normalized_install_command(contract)
    command = Array(contract[:install_command]).dup
    return command if command.empty?
    return command if postinstall_sensitive_contract?(contract)

    fallback_command = opencode_fallback_install_command(contract)
    return fallback_command if fallback_command != command
    return command if command.include?("--ignore-scripts")

    command << "--ignore-scripts"
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
end
