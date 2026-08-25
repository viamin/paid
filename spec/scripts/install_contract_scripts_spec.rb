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

  def supported_version(stdout)
    version = stdout[/^SUPPORTED_VERSION=(.+)$/, 1]
    raise "SUPPORTED_VERSION missing from script output: #{stdout}" unless version

    Gem::Version.new(version)
  end

  def opencode_supported_version
    Gem::Version.new("1.18.9")
  end

  def codex_max_reasoning_level_version
    Gem::Version.new("0.149.1")
  end

  it "keeps codex installs scriptless by default" do
    stdout, stderr, status = run_script("scripts/extract-provider-install-contract.rb", "codex")

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include("SOURCE=npm")
    expect(stdout).to include("--ignore-scripts")
    expect(stdout).not_to include("postinstall.mjs")
  end

  it "ships a codex CLI version that decodes model catalogs advertising the max reasoning level" do
    # Codex 0.122.0 could not decode a model catalog entry advertising the
    # "max" reasoning level ("unknown variant `max`, expected one of `none`,
    # `minimal`, `low`, `medium`, `high`, `xhigh`"), which broke catalog
    # refresh for otherwise-valid requests (viamin/agent-harness#366, fixed
    # in agent-harness 0.36.7, adopted here as part of #3643). The upstream
    # contract now ships >= 0.149.1, which parses the current schema.
    stdout, stderr, status = run_script("scripts/extract-runner-install-contract.rb", "codex")

    expect(status.success?).to be(true), -> { stderr }
    expect(supported_version(stdout)).to be >= codex_max_reasoning_level_version
  end

  it "includes the trusted opencode postinstall step from the upstream contract" do
    stdout, stderr, status = run_script("scripts/extract-provider-install-contract.rb", "opencode")

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include("SOURCE=npm")
    expect(stdout).to include("INSTALL_COMMAND=npm install -g --ignore-scripts opencode-ai@")
    expect(stdout).to include("$(npm root -g)/opencode-ai/postinstall.mjs")
  end

  it "emits the opencode install command for the agent image build path" do
    stdout, stderr, status = run_script("scripts/extract-runner-install-contract.rb", "opencode")

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include("INSTALL_COMMAND=npm install -g --ignore-scripts opencode-ai@")
    expect(stdout).to include("$(npm root -g)/opencode-ai/postinstall.mjs")
  end

  it "selects the postinstall binary architecture from the host instead of assuming amd64" do
    # agent-harness 0.36.0 through 0.36.5 let the opencode-ai postinstall script
    # infer the download target from Node's own os.platform()/os.arch(), which
    # (under some npm install environments) resolved to an amd64 artifact even
    # on an aarch64 host — the binary then failed at runtime with "Dynamic
    # loader not found: /lib64/ld-linux-x86-64.so.2" (viamin/agent-harness#365,
    # fixed in 0.36.6, adopted here as part of #3643). The contract now derives
    # the target platform/arch from `uname` and overrides os.platform/os.arch
    # before invoking the postinstall script, then smoke-tests the resulting
    # binary with `--version` so a mismatched artifact fails the image build
    # instead of shipping broken.
    stdout, stderr, status = run_script("scripts/extract-runner-install-contract.rb", "opencode")

    expect(status.success?).to be(true), -> { stderr }
    expect(stdout).to include('case "$raw_arch" in x86_64|amd64) target_arch=x64 ;; aarch64|arm64) target_arch=arm64 ;;')
    expect(stdout).to include("os.platform = () => platform; os.arch = () => arch;")
    expect(stdout).to include('"$binary_path" --version >/dev/null')
  end

  it "ships an opencode-ai version that recognizes the zai_coding / glm model family" do
    # agent-harness 0.31.0 pinned opencode-ai to 1.3.2, which predates z.ai/glm
    # support and caused ProviderModelNotFoundError for zai_coding/glm-5.x (#3045).
    # The upstream contract now ships >= 1.18.9, which recognizes those models.
    stdout, stderr, status = run_script("scripts/extract-runner-install-contract.rb", "opencode")

    expect(status.success?).to be(true), -> { stderr }
    expect(supported_version(stdout)).to be >= opencode_supported_version
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
end
