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

    it "skips the database runtime role guard for metadata-only contract extraction" do
      expect(script_source).to include('RUBY_CONTRACT_ENV=(env PAID_SKIP_DATABASE_RUNTIME_ROLE_GUARD=true)')
      expect(script_source).to include('CLAUDE_CONTRACT=$("${RUBY_CONTRACT_ENV[@]}" bundle exec ruby')
    end

    it "stamps combo image layers with the dev.paid.agent-image.* labels ComboImageBuilder reads" do
      expect(script_source).to include('COMBO_LABEL_NAMESPACE="dev.paid.agent-image"')
      expect(script_source).to include('COMBO_BASE_DIGEST=$(docker image inspect --format \'{{.Id}}\' "${FULL_IMAGE}")')
      expect(script_source).to include('--label "${COMBO_LABEL_NAMESPACE}.base-digest=${COMBO_BASE_DIGEST}"')
      expect(script_source).to include('--label "${COMBO_LABEL_NAMESPACE}.built-at=${COMBO_BUILT_AT}"')
      expect(script_source).to include('--label "${COMBO_LABEL_NAMESPACE}.languages=${lang}"')
    end

    # @spec POLYGLOT-TEST-009
    it "derives the default combo tag from the full resolver token set while building only extended layers" do
      expect(script_source).to include('# Resolver-token input: COMBO_LANGUAGES may include both base')
      expect(script_source).to include("base_tokens=\"\"")
      expect(script_source).to include("extended_tokens=\"\"")
      expect(script_source).to include('node|python|ruby) base_tokens="${base_tokens} ${combo}" ;;')
      expect(script_source).to include('elixir|go|rust|swift) extended_tokens="${extended_tokens} ${combo}" ;;')
      expect(script_source).to include("ALL_TAG_TOKENS=$(printf '%s\\n' ${extended_tokens} ${base_tokens} | sort -u | tr '\\n' '-' | sed 's/-$//')")
      expect(script_source).to include('COMBO_TAG="${COMBO_TAG:-${IMAGE_NAME}:${ALL_TAG_TOKENS}}"')
      expect(script_source).to include("SORTED_LANGUAGES=$(printf '%s\\n' ${extended_tokens} | sort -u)")
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

    it "skips the runtime role guard for the agent-image job's metadata-only Ruby subprocesses" do
      expect(workflow_source).to include("env:\n      PAID_SKIP_DATABASE_RUNTIME_ROLE_GUARD: \"true\"")
    end

    it "avoids action-managed Bundler caching in the artifact-publishing job" do
      expect(workflow_source).to include("uses: ruby/setup-ruby@95ef2b042f9d7a56d8268cba8559e2842e2ad01b")
      expect(workflow_source).not_to include("bundler-cache: true")
      expect(workflow_source).to include("name: Install Ruby dependencies")
      expect(workflow_source).to include("run: bundle install --jobs 4 --retry 3")
    end

    it "verifies OpenCode execution on a native aarch64 runner, gated on the same relevance check" do
      # An amd64 CI runner cannot catch an install contract that resolves the
      # wrong CPU architecture (viamin/agent-harness#365, adopted for #3643) —
      # only real arm64 hardware exercises the failure. This job installs
      # OpenCode via the same agent-harness-owned contract the Dockerfile
      # uses and executes the resulting binary on ubuntu-24.04-arm.
      expect(workflow_source).to include("image_relevant: ${{ steps.changes.outputs.image_relevant }}")
      expect(workflow_source).to include("opencode-arm64-smoke:")
      expect(workflow_source).to include("needs: agent-image")
      expect(workflow_source).to include("if: needs.agent-image.outputs.image_relevant == 'true'")
      expect(workflow_source).to include("runs-on: ubuntu-24.04-arm")
      expect(workflow_source).to include("bundle exec ruby scripts/extract-runner-install-contract.rb opencode")
      expect(workflow_source).to include("opencode --version")
    end

    it "generates and uploads a smoke-tested image metadata artifact" do
      expect(workflow_source).to include("id: build-paid-agent")
      expect(workflow_source).to include("id: image-digest")
      expect(workflow_source).to include("bundle exec ruby scripts/generate-agent-image-metadata.rb")
      expect(workflow_source).to include("VERIFIED_CHECKS: smoke_test,runner_contract_smoke_test")
      expect(workflow_source).to include("uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1")
      expect(workflow_source).to include("path: tmp/agent-image-metadata.json")
    end
  end

  describe AgentImageDockerfile do
    subject(:dockerfile_source) { Rails.root.join("docker/agent/Dockerfile").read }

    it "keeps the pinned Node.js version in sync with .tool-versions" do
      node_version = Rails.root.join(".tool-versions")
        .read
        .lines
        .find { |line| line.start_with?("nodejs ") }
        .split
        .last

      expect(dockerfile_source).to include("# Install Node.js #{node_version} (pinned version for reproducible builds)")
      expect(dockerfile_source).to include("RUN NODE_VERSION=#{node_version} \\")
      expect(dockerfile_source).to include(
        "# Checksums from official release: https://nodejs.org/download/release/v#{node_version}/SHASUMS256.txt"
      )
    end

    it "installs the oh-my-pi Bun runtime into a non-root shared path" do
      expect(dockerfile_source).to include('export BUN_INSTALL="/usr/local/bun"')
      expect(dockerfile_source).to include('ln -sf "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun')
      expect(dockerfile_source).not_to include('ln -sf /root/.bun/bin/bun /usr/local/bin/bun')
    end

    it "requires the omp install contract inputs" do
      expect(dockerfile_source).to include("ARG OMP_INSTALL_COMMAND")
      expect(dockerfile_source).to include('echo "ERROR: OMP_INSTALL_COMMAND build-arg is required')
    end

    it "installs the pinned bun release with checksum verification before running the omp install command" do
      expect(dockerfile_source).to include('BUN_RELEASE_BASE_URL="https://github.com/oven-sh/bun/releases/download/bun-v${OMP_BUN_VERSION}"')
      expect(dockerfile_source).to include('curl -fsSL "${BUN_RELEASE_BASE_URL}/SHASUMS256.txt"')
      expect(dockerfile_source).to include('sha256sum -c -')
      expect(dockerfile_source).to include('install -m 0755 "${OMP_BUN_TMPDIR}/${BUN_ASSET%.zip}/bun" "${BUN_INSTALL}/bin/bun"')
      expect(dockerfile_source).not_to include('bash /tmp/omp-bun-install.sh')
    end

    it "falls back to Bun's baseline amd64 binary when AVX2 is unavailable" do
      expect(dockerfile_source).to include('if ! grep -qm1 avx2 /proc/cpuinfo; then')
      expect(dockerfile_source).to include('BUN_ASSET="bun-linux-x64-baseline.zip"')
    end

    it "redirects omp install temp files into the larger shared workdir" do
      expect(dockerfile_source).to include('export OMP_INSTALL_WORKDIR="/var/tmp/omp-install"')
      expect(dockerfile_source).to include('export OMP_INSTALL_TMPDIR="${OMP_INSTALL_WORKDIR}/tmp"')
      expect(dockerfile_source).to include('TMPDIR="${OMP_INSTALL_TMPDIR}" TMP="${OMP_INSTALL_TMPDIR}" TEMP="${OMP_INSTALL_TMPDIR}"')
      expect(dockerfile_source).to include('npm_config_tmp="${OMP_INSTALL_TMPDIR}" npm_config_cache="${OMP_INSTALL_WORKDIR}/cache"')
    end

    it "runs the agent-harness omp install command with optional deps omitted for CI disk budget" do
      expect(dockerfile_source).to include('sh -c "${OMP_INSTALL_COMMAND}"')
      expect(dockerfile_source).to include('rm -rf "${OMP_INSTALL_WORKDIR}"')
      expect(dockerfile_source).to include('npm_config_omit=optional')
      expect(dockerfile_source).not_to include('bun install -g "${OMP_PACKAGE}"')
    end

    # @spec CONTAINER-RUNTIME-031
    it "verifies the omp launcher exists after installation" do
      expect(dockerfile_source).to include('OMP_BINARY_PATH="$(command -v omp || true)"')
      expect(dockerfile_source).to include('if [ ! -x "${OMP_BINARY_PATH}" ]; then')
    end

    # @spec CONTAINER-RUNTIME-031
    it "surfaces actionable diagnostics when oh-my-pi post-install checks fail" do
      expect(dockerfile_source).to include('ERROR: omp binary not found on PATH after install')
      expect(dockerfile_source).to include('ERROR: omp binary is not executable:')
      expect(dockerfile_source).to include('ERROR: bun version mismatch after OMP install')
      expect(dockerfile_source).to include('OMP_BUN_ACTUAL_VERSION="$(bun --version || true)"')
      expect(dockerfile_source).to include('TMPDIR=${TMPDIR:-unset}')
      expect(dockerfile_source).to include('npm config get prefix')
    end

    it "copies the vendored git credential helper from the agent image directory" do
      helper_path = Rails.root.join("docker/agent/scripts/git-credential-paid")

      expect(helper_path).to exist
      expect(dockerfile_source).to include("COPY docker/agent/scripts/git-credential-paid /usr/local/bin/git-credential-paid")
    end

    # @spec CONTAINER-RUNTIME-036
    it "installs warden from a checksum-verified npm tarball with scripts disabled" do
      expect(dockerfile_source).to include("RUN WARDEN_VERSION=")
      expect(dockerfile_source).to include("https://registry.npmjs.org/@sentry/warden/-/warden-${WARDEN_VERSION}.tgz")
      expect(dockerfile_source).to include('WARDEN_CHECKSUM="')
      expect(dockerfile_source).to include("sha256sum -c -")
      expect(dockerfile_source).to include("npm install -g --ignore-scripts \"./${TARBALL}\"")
      expect(dockerfile_source).to include("warden --version")
    end

    # @spec CONTAINER-RUNTIME-036
    it "vendors the warden license notice, default policy, and scan wrapper" do
      license_path = Rails.root.join("docker/agent/warden/LICENSE")
      policy_path = Rails.root.join("docker/agent/warden/warden.toml")
      wrapper_path = Rails.root.join("docker/agent/scripts/warden-scan")

      expect(license_path).to exist
      expect(license_path.read).to include("FSL-1.1-ALv2")
      expect(policy_path).to exist
      expect(policy_path.read).to include("security-review")
      expect(wrapper_path).to exist
      expect(wrapper_path).to be_executable
      expect(dockerfile_source).to include("COPY docker/agent/scripts/warden-scan /usr/local/bin/warden-scan")
      expect(dockerfile_source).to include("COPY docker/agent/warden /opt/warden")
    end

    # @spec CONTAINER-RUNTIME-036
    it "gives the warden scan wrapper repo-config preference and an in-container base resolution" do
      wrapper = Rails.root.join("docker/agent/scripts/warden-scan").read

      expect(wrapper).to include("WARDEN_BASE_SHA")
      expect(wrapper).to include("origin/HEAD")
      expect(wrapper).to include("HEAD~1")
      expect(wrapper).to include("--config-path /opt/warden/warden.toml")
      expect(wrapper).to include("warden run")
      expect(wrapper).to include("--fail-on high")
    end

    # @spec CONTAINER-RUNTIME-036
    it "bridges proxy-routed OpenAI credentials into warden's WARDEN_OPENAI_* convention" do
      wrapper = Rails.root.join("docker/agent/scripts/warden-scan").read

      expect(wrapper).to include('export WARDEN_OPENAI_API_KEY="${WARDEN_OPENAI_API_KEY:-${OPENAI_API_KEY:-}}"')
      expect(wrapper).to include('export WARDEN_OPENAI_BASE_URL="${WARDEN_OPENAI_BASE_URL:-${OPENAI_BASE_URL:-}}"')
    end
  end
end
