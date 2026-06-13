# frozen_string_literal: true

require "rails_helper"
require "open3"

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

  it "verifies npm install commands stay scriptless before eval" do
    expect(install_wrapper_source).to include('case "$INSTALL_COMMAND" in')
    expect(install_wrapper_source).to include("must include --ignore-scripts")
  end
end
