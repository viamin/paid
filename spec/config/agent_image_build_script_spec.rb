# frozen_string_literal: true

require "rails_helper"

class AgentImageBuildScript < Pathname
end

class AgentImageWorkflow < Pathname
end

class AgentImageDockerfile < Pathname
end

RSpec.describe AgentImageBuildScript, :no_db do
  describe "build script" do
    subject(:script_source) { Rails.root.join("scripts/build-agent-image.sh").read }

    it "uses the renamed runner install-contract extractor consistently" do
      expect(script_source).to include("scripts/extract-runner-install-contract.rb")
      expect(script_source).not_to include("scripts/extract-provider-install-contract.rb")
    end

    it "extracts the Bundler version from Gemfile.lock for the agent build" do
      expect(script_source).to include("BUNDLER_VERSION=$(awk '/^BUNDLED WITH$/{getline; gsub(/^ +/, \"\", $0); print $0}'")
      expect(script_source).to include('--build-arg "BUNDLER_VERSION=${BUNDLER_VERSION}"')
    end

    it "passes the oh-my-pi install command through from agent-harness" do
      expect(script_source).to include('OMP_INSTALL_COMMAND=$(echo "${OMP_CONTRACT}" | sed -n \'s/^INSTALL_COMMAND=//p\')')
      expect(script_source).to include('--build-arg "OMP_INSTALL_COMMAND=${OMP_INSTALL_COMMAND}"')
    end

    it "passes the oh-my-pi Bun runtime pin through from agent-harness" do
      expect(script_source).to include('OMP_BUN_VERSION=$(echo "${OMP_CONTRACT}" | sed -n \'s/^BUN_VERSION=//p\')')
      expect(script_source).to include('--build-arg "OMP_BUN_VERSION=${OMP_BUN_VERSION}"')
    end

    it "passes the oh-my-pi Bun install script URL through from agent-harness" do
      expect(script_source).to include('OMP_BUN_INSTALL_SCRIPT_URL=$(echo "${OMP_CONTRACT}" | sed -n \'s/^BUN_INSTALL_SCRIPT_URL=//p\')')
      expect(script_source).to include('--build-arg "OMP_BUN_INSTALL_SCRIPT_URL=${OMP_BUN_INSTALL_SCRIPT_URL}"')
    end
  end

  describe AgentImageWorkflow do
    subject(:workflow_source) { Rails.root.join(".github/workflows/agent-image.yml").read }

    it "compares extracted lockfile contract versions instead of grepping zero-context diffs" do
      expect(workflow_source).to include('previous_bundler_version=$(extract_lockfile_bundler_version "${BASE_SHA}")')
      expect(workflow_source).to include('current_bundler_version=$(extract_lockfile_bundler_version "${HEAD_SHA}")')
      expect(workflow_source).to include('bundler: ${previous_bundler_version:-missing} -> ${current_bundler_version:-missing}\n')
      expect(workflow_source).not_to include('| grep -E')
    end

    it "treats the shared install-contract helper as agent-image relevant" do
      expect(workflow_source).to include("- scripts/lib/install_contract_helpers.rb")
      expect(workflow_source).to include("scripts/lib/install_contract_helpers.rb|\\")
    end

    it "passes the oh-my-pi Bun install script URL through to the docker build" do
      expect(workflow_source).to include('bun_install_script_url=$(echo "$contract" | sed -n \'s/^BUN_INSTALL_SCRIPT_URL=//p\')')
      expect(workflow_source).to include('echo "bun_install_script_url=$bun_install_script_url" >> "$GITHUB_OUTPUT"')
      expect(workflow_source).to include("OMP_BUN_INSTALL_SCRIPT_URL=${{ steps.omp-contract.outputs.bun_install_script_url }}")
    end
  end

  describe AgentImageDockerfile do
    subject(:dockerfile_source) { Rails.root.join("docker/agent/Dockerfile").read }

    it "installs the oh-my-pi Bun runtime into a non-root shared path" do
      expect(dockerfile_source).to include('export BUN_INSTALL="/usr/local/bun"')
      expect(dockerfile_source).to include('ln -sf "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun')
      expect(dockerfile_source).not_to include('ln -sf /root/.bun/bin/bun /usr/local/bin/bun')
    end

    it "uses the agent-harness omp install command after provisioning Bun" do
      expect(dockerfile_source).to include("ARG OMP_INSTALL_COMMAND")
      expect(dockerfile_source).to include("ARG OMP_BUN_INSTALL_SCRIPT_URL")
      expect(dockerfile_source).to include('echo "ERROR: OMP_INSTALL_COMMAND build-arg is required')
      expect(dockerfile_source).to include('echo "ERROR: OMP_BUN_INSTALL_SCRIPT_URL build-arg is required')
      expect(dockerfile_source).to include('curl -fsSL "${OMP_BUN_INSTALL_SCRIPT_URL}" | BUN_VERSION="${OMP_BUN_VERSION}" bash')
      expect(dockerfile_source).to include('sh -c "${OMP_INSTALL_COMMAND}"')
      expect(dockerfile_source).not_to include('bun install -g "${OMP_PACKAGE}"')
    end

    it "verifies the omp launcher exists after installation" do
      expect(dockerfile_source).to include('OMP_BINARY_PATH="$(command -v omp || true)"')
      expect(dockerfile_source).to include('test -x "${OMP_BINARY_PATH}"')
    end
  end
end
