# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "open3"
require "psych"
require "tmpdir"

class AgentImageBuildScript < Pathname
end

class AgentImageWorkflow < Pathname
end

class AgentImageDockerfile < Pathname
end

class AgentImageFetchHelper < Pathname
end

class PaidJourneyLaunchContract < Pathname
end

class RemoteDockerSetupGuide < Pathname
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

    let(:workflow) do
      Psych.safe_load_file(Rails.root.join(".github/workflows/agent-image.yml"), aliases: true)
    end

    def ruby_setup_steps
      workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }
               .select { |step| step.fetch("uses", "").start_with?("ruby/setup-ruby@") }
    end

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

    # @spec CONTAINER-RUNTIME-031
    it "allows enough time for a cold contract-owned CLI rebuild and every smoke suite" do
      expect(workflow.dig("jobs", "agent-image", "timeout-minutes")).to eq(90)
    end

    # The action ref is asserted as an opaque 40-character SHA instead of a
    # hardcoded pin: Dependabot owns the GitHub Action bump, so naming the exact
    # commit here would turn every bump into a spec edit while asserting nothing
    # extra. What matters is that the ref stays SHA-pinned (never a floating tag)
    # and that no job delegates Bundler caching to the action.
    it "avoids action-managed Bundler caching in the artifact-publishing job" do
      setup_steps = ruby_setup_steps

      expect(setup_steps).not_to be_empty
      setup_steps.each do |step|
        expect(step.fetch("uses")).to match(/\Aruby\/setup-ruby@[0-9a-f]{40}\z/)
        expect(step.fetch("with", {})).not_to have_key("bundler-cache")
      end

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
      expect(workflow_source).to include("VERIFIED_CHECKS: smoke_test,journey_launch_contract_smoke_test,runner_contract_smoke_test")
      expect(workflow_source).to include("uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2")
      expect(workflow_source).to include("path: tmp/agent-image-metadata.json")
    end

    # @spec LIVE-PREVIEW-012
    it "runs the Paid journey launch contract in the built agent image" do
      expect(workflow_source).to include("- .paid/journeys.md")
      expect(workflow_source).to include("scripts/test-paid-journey-launch-contract.sh")
      expect(workflow_source).to include("name: Journey launch-contract smoke test")
      expect(workflow_source).to include("run: ./scripts/test-paid-journey-launch-contract.sh")
    end

    # @spec LIVE-PREVIEW-012
    it "runs the journey launch contract when its guide or script changes on main" do
      push_paths = workflow.fetch(true).fetch("push").fetch("paths")

      expect(push_paths).to include(
        ".paid/journeys.md",
        "scripts/test-paid-journey-launch-contract.sh",
        "scripts/test-paid-journey-launch-contract-inner.sh"
      )
    end
  end

  describe PaidJourneyLaunchContract do
    subject(:script_source) { Rails.root.join("scripts/test-paid-journey-launch-contract.sh").read }

    let(:inner_script_path) { Rails.root.join("scripts/test-paid-journey-launch-contract-inner.sh") }
    let(:inner_script_source) { inner_script_path.read }

    # @spec LIVE-PREVIEW-012
    it "resolves the guide's launch command inside the paid-agent image" do
      expect(script_source).to include("docker run --rm")
      expect(script_source).to include("test-paid-journey-launch-contract-inner.sh")
      expect(inner_script_path).to exist
      expect(inner_script_source).to include(".paid/journeys.md")
      expect(inner_script_source).to include("command -v")
    end

    # @spec LIVE-PREVIEW-012
    it "rejects a launch command that needs the tmux and Overmind supervisor the image lacks" do
      expect(inner_script_source).to include("bin/dev")
      expect(inner_script_source).to include("tmux")
      expect(inner_script_source).to include("overmind")
    end

    # @spec LIVE-PREVIEW-012
    it "accepts a launch command the checkout and the image can run" do
      stdout, stderr, status = run_launch_contract_check(
        launch_command: "bundle exec bin/rails server -b 0.0.0.0 -p 3000",
        scripts: [ "bin/rails" ]
      )

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("bundle exec bin/rails server -b 0.0.0.0 -p 3000")
    end

    # @spec LIVE-PREVIEW-012
    it "rejects a launch command whose repository script is missing from the checkout" do
      _stdout, stderr, status = run_launch_contract_check(
        launch_command: "bundle exec bin/rails server -b 0.0.0.0 -p 3000",
        scripts: []
      )

      expect(status).not_to be_success
      expect(stderr).to include("'bin/rails' is missing from the checkout")
    end

    # @spec LIVE-PREVIEW-012
    it "rejects a launch command the image cannot resolve" do
      _stdout, stderr, status = run_launch_contract_check(
        launch_command: "paid-journey-missing-command server",
        scripts: []
      )

      expect(status).not_to be_success
      expect(stderr).to include("'paid-journey-missing-command' is not available in this image")
    end

    # @spec LIVE-PREVIEW-012
    it "rejects a bin/dev launch command when the image ships no supervisor" do
      _stdout, stderr, status = run_launch_contract_check(
        launch_command: "PORT=3000 bin/dev",
        scripts: [ "bin/dev" ]
      )

      expect(status).not_to be_success
      expect(stderr).to include("'bin/dev' needs 'tmux', which this image does not ship")
      expect(stderr).to include("'bin/dev' needs 'overmind', which this image does not ship")
    end

    # Runs the container-side check against a throwaway checkout so the
    # assertions never depend on the host's own tooling.
    def run_launch_contract_check(launch_command:, scripts:)
      Dir.mktmpdir("paid-journey-launch-contract") do |dir|
        guide_path = write_guide(dir, launch_command)
        scripts.each { |script| write_script(dir, script) }
        stub_dir = write_stub_bin(dir)

        Open3.capture3(
          { "PATH" => stub_dir },
          File.join(stub_dir, "bash"),
          inner_script_path.to_s,
          guide_path,
          chdir: dir
        )
      end
    end

    def write_guide(dir, launch_command)
      guide_path = File.join(dir, ".paid", "journeys.md")
      FileUtils.mkdir_p(File.dirname(guide_path))
      File.write(guide_path, "# Journeys\n\n```bash\n(#{launch_command}) > tmp/app.log 2>&1 &\n```\n")
      guide_path
    end

    def write_script(dir, script)
      script_path = File.join(dir, script)
      FileUtils.mkdir_p(File.dirname(script_path))
      File.write(script_path, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, script_path)
    end

    # A PATH holding only the utilities the check needs, so the assertions stay
    # independent of the host's own tooling: a supervisor installed on the host
    # must not satisfy the `bin/dev` rule, and the launch command's executable
    # must resolve from the stub rather than from the developer's machine.
    def write_stub_bin(dir)
      stub_dir = File.join(dir, "stubbin")
      FileUtils.mkdir_p(stub_dir)
      %w[bash sed dirname].each do |utility|
        source = ENV.fetch("PATH").split(File::PATH_SEPARATOR).filter_map do |entry|
          candidate = File.join(entry, utility)
          File.executable?(candidate) ? candidate : nil
        end.first
        raise "Unable to locate #{utility} on PATH" if source.nil?

        FileUtils.ln_s(source, File.join(stub_dir, utility))
      end
      File.write(File.join(stub_dir, "bundle"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(stub_dir, "bundle"))
      stub_dir
    end
  end

  describe AgentImageDockerfile do
    subject(:dockerfile_source) { Rails.root.join("docker/agent/Dockerfile").read }

    # @spec TOOLCHAIN-PIN-053
    it "retries the checksum-verified ast-grep release download" do
      expect(dockerfile_source).to include("# Install ast-grep (AST-based code search/lint)")
      expect(dockerfile_source).to include(
        'fetch-release-asset "https://github.com/ast-grep/ast-grep/releases/download/${AST_GREP_VERSION}/${ZIPFILE}" "${ZIPFILE}"'
      )
      expect(dockerfile_source).to include('echo "${EXPECTED_CHECKSUM}  ${ZIPFILE}" | sha256sum -c -')
    end

    # @spec TOOLCHAIN-PIN-054
    it "retries the PostgreSQL package repository signing-key download" do
      expect(dockerfile_source).to include("curl --fail --show-error --location --retry 5 --retry-all-errors --retry-delay 10")
      expect(dockerfile_source).to include("https://www.postgresql.org/media/keys/ACCC4CF8.asc")
      expect(dockerfile_source).to include("/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc")
    end

    # @spec TOOLCHAIN-PIN-053
    it "routes every GitHub release-asset download through the retrying fetch helper" do
      expect(dockerfile_source).to include(
        "COPY docker/agent/scripts/fetch-release-asset /usr/local/bin/fetch-release-asset"
      )

      %w[
        https://github.com/ast-grep/ast-grep/releases/download
        https://github.com/boyter/scc/releases/download
        https://github.com/rathole-org/rathole/releases/download
        https://github.com/rtk-ai/rtk/releases/download
      ].each do |asset_base|
        expect(dockerfile_source).to include("fetch-release-asset \"#{asset_base}")
      end

      expect(dockerfile_source).to include('fetch-release-asset "${BUN_RELEASE_BASE_URL}/SHASUMS256.txt"')
      expect(dockerfile_source).to include('fetch-release-asset "${BUN_RELEASE_BASE_URL}/${BUN_ASSET}"')
      expect(dockerfile_source).to include('fetch-release-asset "${CURSOR_ARTIFACT_URL}" /tmp/cursor-artifact.tar.gz')
      expect(dockerfile_source).not_to match(/curl[^\n]*github\.com[^\n]*\/releases\/download/)
    end

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
      expect(dockerfile_source).to include('fetch-release-asset "${BUN_RELEASE_BASE_URL}/SHASUMS256.txt"')
      expect(dockerfile_source).to include('sha256sum -c -')
      expect(dockerfile_source).to include('install -m 0755 "${OMP_BUN_TMPDIR}/${BUN_ASSET%.zip}/bun" "${BUN_INSTALL}/bin/bun"')
      expect(dockerfile_source).not_to include('bash /tmp/omp-bun-install.sh')
    end

    it "falls back to Bun's baseline amd64 binary when AVX2 is unavailable" do
      expect(dockerfile_source).to include('if ! grep -qm1 avx2 /proc/cpuinfo; then')
      expect(dockerfile_source).to include('BUN_ASSET="bun-linux-x64-baseline.zip"')
    end

    # @spec CONTAINER-RUNTIME-029
    it "verifies the current Kilocode SQLite seed after warming the CLI" do
      expect(dockerfile_source).to include('timeout -k 10s 120s kilo session list')
      expect(dockerfile_source).to include(
        "find /home/agent/.local/share/kilo -maxdepth 1 -name '*.db' -print -quit"
      )
      expect(dockerfile_source).not_to include("test -f /home/agent/.local/share/kilo/kilo.db")
      expect(dockerfile_source).not_to include("test -f /home/agent/.local/share/kilo/kilo-rc.db")
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

  describe AgentImageFetchHelper do
    subject(:helper_path) { Rails.root.join("docker/agent/scripts/fetch-release-asset") }

    # @spec TOOLCHAIN-PIN-053
    it "exists and is executable so the image build can invoke it" do
      expect(helper_path).to exist
      expect(helper_path).to be_executable
    end

    # @spec TOOLCHAIN-PIN-053
    it "fails fast per transfer via curl's own retry flags" do
      helper = helper_path.read

      expect(helper).to include("Usage: fetch-release-asset URL OUTPUT_PATH")
      expect(helper).to include("--fail")
      expect(helper).to include("--show-error")
      expect(helper).to include("--location")
      expect(helper).to include("--retry-all-errors")
      expect(helper).to include("--connect-timeout")
      expect(helper).to include("--max-time")
    end

    # @spec TOOLCHAIN-PIN-053
    it "retries with a bounded escalating backoff between attempts" do
      helper = helper_path.read

      expect(helper).to include('attempts="${FETCH_RELEASE_ASSET_ATTEMPTS:-5}"')
      expect(helper).to include('delay="${FETCH_RELEASE_ASSET_INITIAL_DELAY_SECONDS:-15}"')
      expect(helper).to include("delay=$((delay * 2))")
      expect(helper).to include("failed to download")
    end

    # @spec TOOLCHAIN-PIN-053
    it "keeps checksum verification with the caller instead of trusting the transport" do
      expect(helper_path.read).not_to include("sha256sum")

      expect(Rails.root.join("docker/agent/Dockerfile").read).to include('sha256sum -c -')
    end
  end

  describe RemoteDockerSetupGuide do
    # @spec CONTAINER-RUNTIME-046
    describe "QNAP native build guidance" do
      subject(:guide_source) { Rails.root.join("docs/guides/remote-docker-setup.md").read }

      it "documents the glibc fchmodat2 root cause of the QNAP tar extraction failure" do
        expect(guide_source).to include("Do not run a native `docker build` of `docker/agent/Dockerfile` directly against QNAP Container Station")
        expect(guide_source).to include("Cannot change mode to rwxr-xr-x: Bad address")
        expect(guide_source).to include("fchmodat2")
        expect(guide_source).to include("issue `#3544`")
      end

      it "points affected hosts at the docker save/load transfer path instead of a tar workaround" do
        expect(guide_source).to include("docker save | docker load")
        expect(guide_source).to include("not something this Dockerfile can route around")
      end
    end
  end
end
