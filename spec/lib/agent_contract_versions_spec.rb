# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("scripts/lib/agent_contract_versions")

RSpec.describe AgentContractVersions, :no_db do
  # Stands in for shelling out to the extract-contract scripts, keyed by the
  # arguments bin/update passes.
  def runner(responses)
    ->(script, provider) { responses[[ script, provider ]] }
  end

  def provider_output(version)
    "SOURCE=npm\nPACKAGE=@acme/cli\nSUPPORTED_VERSION=#{version}\n"
  end

  describe "#versions" do
    # @spec TOOLCHAIN-PIN-031
    it "reports the version each contract declares" do
      contracts = described_class.new(
        providers: %w[codex opencode],
        runner: runner(
          [ described_class::PROVIDER_SCRIPT, "codex" ] => provider_output("0.122.0"),
          [ described_class::PROVIDER_SCRIPT, "opencode" ] => provider_output("1.18.9")
        )
      )

      expect(contracts.versions).to eq("codex" => "0.122.0", "opencode" => "1.18.9")
    end

    # An unpinned contract installs whatever the registry publishes, which is a
    # different fact from a contract that could not be read.
    #
    # @spec TOOLCHAIN-PIN-031
    it "distinguishes a contract that declares no version from one it cannot read" do
      contracts = described_class.new(
        providers: %w[copilot cursor],
        runner: runner(
          [ described_class::PROVIDER_SCRIPT, "copilot" ] => provider_output(""),
          [ described_class::PROVIDER_SCRIPT, "cursor" ] => nil
        )
      )

      expect(contracts.versions).to eq(
        "copilot" => described_class::UNPINNED,
        "cursor" => nil
      )
    end
  end

  describe "#readable?" do
    # @spec TOOLCHAIN-PIN-033
    it "is false when no contract could be read at all" do
      contracts = described_class.new(providers: %w[codex omp], runner: runner({}))

      expect(contracts).not_to be_readable
    end

    # @spec TOOLCHAIN-PIN-033
    it "is true when at least one contract answered" do
      contracts = described_class.new(
        providers: %w[codex omp],
        runner: runner([ described_class::PROVIDER_SCRIPT, "codex" ] => provider_output("0.122.0"))
      )

      expect(contracts).to be_readable
    end
  end

  describe "#oh_my_pi_runtime" do
    let(:runner_output) do
      "SOURCE=npm\n" \
        "PACKAGE=@oh-my-pi/pi-coding-agent\n" \
        "SUPPORTED_VERSION=17.0.1\n" \
        "BUN_VERSION=1.3.14\n" \
        "BUN_INSTALL_SCRIPT_URL=https://bun.sh/install\n"
    end

    # @spec TOOLCHAIN-PIN-034
    it "reads the package and its Bun runtime from the runner contract" do
      contracts = described_class.new(
        providers: [],
        runner: runner([ described_class::RUNNER_SCRIPT, "omp" ] => runner_output)
      )

      expect(contracts.oh_my_pi_runtime).to eq(
        package: "@oh-my-pi/pi-coding-agent", version: "17.0.1", bun_version: "1.3.14"
      )
    end

    # @spec TOOLCHAIN-PIN-033
    it "returns nothing when the contract cannot be read" do
      contracts = described_class.new(providers: [], runner: runner({}))

      expect(contracts.oh_my_pi_runtime).to be_nil
    end

    # A partial contract must not be treated as authoritative: syncing a package
    # version while leaving Bun stale would ship a runtime the agent cannot run on.
    #
    # @spec TOOLCHAIN-PIN-034
    it "returns nothing when the contract omits the Bun runtime" do
      contracts = described_class.new(
        providers: [],
        runner: runner(
          [ described_class::RUNNER_SCRIPT, "omp" ] => "PACKAGE=@oh-my-pi/pi-coding-agent\nSUPPORTED_VERSION=17.0.1\n"
        )
      )

      expect(contracts.oh_my_pi_runtime).to be_nil
    end
  end
end
