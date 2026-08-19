# frozen_string_literal: true

require "open3"

# Reads the agent CLI versions declared by agent-harness installation contracts.
#
# Paid holds no pin for these: the agent image and the devcontainer both read
# the contract at build time, so a Paid-side pin would diverge from the version
# agent-harness was tested against. This class exists so bin/update can *report*
# what the contracts declare — and how far behind upstream they are — without
# pretending Paid can change them.
#
# @spec TOOLCHAIN-PIN-031
# @spec TOOLCHAIN-PIN-033
class AgentContractVersions
  PROVIDER_SCRIPT = "scripts/extract-provider-install-contract.rb"
  RUNNER_SCRIPT = "scripts/extract-runner-install-contract.rb"

  # A contract that declares no version installs whatever the registry publishes.
  # That is a different fact from a contract that could not be read at all, and
  # the two must not collapse into one "unknown".
  UNPINNED = :unpinned

  # Shells out the same way the devcontainer and the agent image build do, so
  # bin/update reports the versions those environments will actually install.
  def self.bundler_runner(root)
    lambda do |script, provider|
      stdout, _stderr, status = Open3.capture3(
        "bundle", "exec", "ruby", script, provider, chdir: root.to_s
      )
      status.success? ? stdout : nil
    rescue StandardError
      nil
    end
  end

  def initialize(providers:, runner:)
    @providers = providers
    @runner = runner
  end

  # Provider name => declared version, UNPINNED, or nil when unreadable.
  def versions
    @versions ||= @providers.to_h { |provider| [ provider, version_for(provider) ] }
  end

  # False when no contract could be read at all — the signal that the check was
  # skipped rather than that every provider is unpinned.
  def readable?
    versions.values.any? { |version| !version.nil? }
  end

  # Oh My Pi carries a Bun runtime requirement that the devcontainer installer
  # duplicates as a default, so it is read from the runner contract that exposes
  # both values.
  #
  # @spec TOOLCHAIN-PIN-034
  def oh_my_pi_runtime
    output = @runner.call(RUNNER_SCRIPT, "omp")
    return nil if output.nil?

    version = field(output, "SUPPORTED_VERSION")
    bun_version = field(output, "BUN_VERSION")
    return nil if version.nil? || bun_version.nil?

    { package: field(output, "PACKAGE"), version: version, bun_version: bun_version }
  end

  private

  def version_for(provider)
    output = @runner.call(PROVIDER_SCRIPT, provider)
    return nil if output.nil?

    field(output, "SUPPORTED_VERSION") || UNPINNED
  end

  def field(output, name)
    value = output[/^#{Regexp.escape(name)}=(.*)$/, 1].to_s.strip
    value.empty? ? nil : value
  end
end
