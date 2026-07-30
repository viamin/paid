# frozen_string_literal: true

require "rails_helper"
require "open3"
require Rails.root.join("scripts/lib/install_contract_helpers").to_s

class InstallContractScripts
end

RSpec.describe InstallContractScripts, :no_db do
  subject(:install_wrapper_source) { Rails.root.join("scripts/install-from-contract.sh").read }

  def run_script(script_path, provider)
    # The subprocess inherits this process's environment (including bundler's
    # BUNDLE_* config and .bundle/config via chdir), so no env needs to be
    # forwarded explicitly. Passing BUNDLE_PATH manually previously coerced an
    # unset value to "", which broke gem resolution in the child.
    Open3.capture3("bundle", "exec", "ruby", script_path, provider, chdir: Rails.root.to_s)
  end

  it "keeps codex installs scriptless by default" do
    stdout, stderr, status = run_script("scripts/extract-provider-install-contract.rb", "codex")

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include("SOURCE=npm")
    expect(stdout).to include("--ignore-scripts")
    expect(stdout).not_to include("postinstall.mjs")
  end

  it "adds the trusted opencode postinstall fallback for the current upstream contract" do
    stdout, stderr, status = run_script("scripts/extract-provider-install-contract.rb", "opencode")

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include("SOURCE=npm")
    expect(stdout).to include("INSTALL_COMMAND=npm install -g --ignore-scripts opencode-ai@")
    expect(stdout).to include("node $(npm root -g)/opencode-ai/postinstall.mjs")
  end

  it "emits the opencode install command for the agent image build path" do
    stdout, stderr, status = run_script("scripts/extract-runner-install-contract.rb", "opencode")

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include("INSTALL_COMMAND=npm install -g --ignore-scripts opencode-ai@")
    expect(stdout).to include("node $(npm root -g)/opencode-ai/postinstall.mjs")
  end

  it "overrides the opencode version past agent-harness's 1.3.2 pin until the upstream bump ships" do
    stdout, stderr, status = run_script("scripts/extract-runner-install-contract.rb", "opencode")

    expect(status.success?).to be(true), -> { stderr }
    # agent-harness 0.31.0 pins opencode to 1.3.2, which lacks z.ai/glm support.
    # install_contract_helpers forces a newer pin (>= 1.18) pending the upstream
    # bump. When the override is removed this test should be deleted with it.
    expect(stdout).to include("opencode-ai@1.1")
    expect(stdout).not_to include("opencode-ai@1.3.2")
  end

  it "lets OPENCODE_VERSION_OVERRIDE opt out of the opencode version pin" do
    stdout, stderr, status = Open3.capture3(
      { "OPENCODE_VERSION_OVERRIDE" => "" },
      "bundle", "exec", "ruby", "scripts/extract-runner-install-contract.rb", "opencode",
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include("opencode-ai@1.3.2")
  end

  it "falls back to runtime installation metadata for omp" do
    stdout, stderr, status = run_script("scripts/extract-runner-install-contract.rb", "omp")

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include("SOURCE=npm")
    expect(stdout).to include("PACKAGE=@oh-my-pi/pi-coding-agent")
    expect(stdout).to include("INSTALL_COMMAND=npm install -g --ignore-scripts @oh-my-pi/pi-coding-agent@")
    expect(stdout).to include("BUN_VERSION=")
    expect(stdout).to include("BUN_INSTALL_SCRIPT_URL=https://bun.sh/install")
  end

  it "verifies npm install commands stay scriptless before eval" do
    expect(install_wrapper_source).to include('case "$INSTALL_COMMAND" in')
    expect(install_wrapper_source).to include("must include --ignore-scripts")
  end

  describe "opencode version override" do
    def override_command(contract_version, install_version = contract_version)
      InstallContractHelpers.apply_opencode_version_override(
        { package_name: "opencode-ai", version: contract_version },
        %W[npm install -g --ignore-scripts opencode-ai@#{install_version}]
      ).join(" ")
    end

    it "upgrades an older contract version up to the fallback" do
      expect(override_command("1.3.2")).to include("opencode-ai@1.18.10")
    end

    it "does not downgrade once the upstream contract reaches the fallback" do
      # Guards against the temporary override silently pinning opencode to a
      # stale floor after agent-harness#316 ships a newer pin.
      expect(override_command("2.0.0")).to include("opencode-ai@2.0.0")
      expect(override_command("2.0.0")).not_to include("opencode-ai@1.18.10")
    end

    it "treats an unparseable contract version as below the floor" do
      # The contract *metadata* version is unparseable, but the install command
      # still carries a normal numeric version the regex can rewrite.
      expect(override_command("not-a-version", "1.3.2")).to include("opencode-ai@1.18.10")
    end

    it "leaves non-opencode packages untouched" do
      out = InstallContractHelpers.apply_opencode_version_override(
        { package_name: "@oh-my-pi/pi-coding-agent", version: "1.0.0" },
        %w[npm install @oh-my-pi/pi-coding-agent@1.0.0]
      )
      expect(out.join(" ")).to include("@oh-my-pi/pi-coding-agent@1.0.0")
    end
  end
end
