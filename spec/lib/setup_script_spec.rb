# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

RSpec.describe "bin/setup" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  let(:script_source) { File.expand_path("../../bin/setup", __dir__) }
  let(:log_truncator_source) { File.expand_path("../../lib/paid/log_truncator.rb", __dir__) }

  it "starts bin/dev detached with restart-if-running when server startup is enabled" do
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = setup_script_env(dir)

      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("== Starting development server ==")
      expect(File.read(File.join(dir, "dev-args.log")).split).to eq(%w[--detach --restart-if-running])
    end
  end

  it "skips bin/dev when --skip-server is provided" do
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = setup_script_env(dir)

      stdout, stderr, status = Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("== Setup complete! ==")
      expect(File.exist?(File.join(dir, "dev-args.log"))).to be(false)
    end
  end

  it "writes the metrics token file from METRICS_TOKEN so Prometheus scrape auth stays in sync" do
    # Regression guard: docker-compose.observability.yml mounts
    # ./prometheus/metrics_token into the Prometheus container at the path
    # referenced by the `paid` scrape job's authorization.credentials_file.
    # bin/setup materializes that file from the host's METRICS_TOKEN env var
    # so the value matches what docker-compose.yml propagates into the web
    # service (which the Rails side reads to decide whether to enforce auth).
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = setup_script_env(dir).merge("METRICS_TOKEN" => "test-scraper-token")

      Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      token_path = File.join(dir, "prometheus", "metrics_token")
      expect(File.read(token_path)).to eq("test-scraper-token")
    end
  end

  it "preserves the checked-in empty metrics token file when METRICS_TOKEN is unset" do
    # When METRICS_TOKEN is absent from the process environment, bin/setup
    # must leave the shared token file untouched. This prevents a worker
    # container running bin/setup --skip-server from erasing a token that
    # the web/bootstrap path already materialized for Prometheus.
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = setup_script_env(dir)

      Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      token_path = File.join(dir, "prometheus", "metrics_token")
      expect(File.exist?(token_path)).to be(true)
      expect(File.read(token_path)).to eq("")
    end
  end

  it "does not overwrite an existing metrics token file when METRICS_TOKEN is unset" do
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      token_path = File.join(dir, "prometheus", "metrics_token")
      File.write(token_path, "bootstrap-token")
      env = setup_script_env(dir)

      Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      expect(File.read(token_path)).to eq("bootstrap-token")
    end
  end

  it "installs the lockfile Bundler version before running bundle when missing" do
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, installed_bundler_versions: [])
      env = setup_script_env(dir)

      stdout, stderr, status = Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Installing Bundler 4.0.12 to match Gemfile.lock")
      expect(File.read(File.join(dir, "gem-install.log"))).to include("--no-document bundler:4.0.12")
    end
  end

  def prepare_script_fixture(dir, installed_bundler_versions: [ "4.0.12" ])
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "lib", "paid"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))
    FileUtils.mkdir_p(File.join(dir, "log", "dev-update"))
    FileUtils.mkdir_p(File.join(dir, "workspace-root"))
    FileUtils.mkdir_p(File.join(dir, "prometheus"))
    File.write(File.join(dir, "prometheus", "metrics_token"), "")
    File.write(File.join(dir, "Gemfile.lock"), "BUNDLED WITH\n   4.0.12\n")
    File.write(File.join(dir, "installed-bundlers.txt"), installed_bundler_versions.join("\n"))

    script_path = File.join(dir, "bin", "setup")
    FileUtils.cp(script_source, script_path)
    FileUtils.chmod("+x", script_path)
    FileUtils.cp(log_truncator_source, File.join(dir, "lib", "paid", "log_truncator.rb"))

    write_executable(
      File.join(dir, "bin", "ensure-worktree-databases"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "bin", "dev"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\n' "$@" > "#{dir}/dev-args.log"
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "bin", "yarn-postinstall"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "bin", "rails"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "bundle"),
      <<~BASH
        #!/usr/bin/env bash
        command="$1"
        version="$1"
        if [[ "$command" == _*_ ]]; then
          command="$2"
        fi

        if [[ "$version" == _*_ ]]; then
          required_version="${version#_}"
          required_version="${required_version%_}"
          if ! grep -qx "$required_version" "#{dir}/installed-bundlers.txt"; then
            echo "missing bundler version: $required_version" >&2
            exit 1
          fi
        fi

        case "$command" in
          --version)
            exit 0
            ;;
          check)
            exit 0
            ;;
          install)
            exit 0
            ;;
          *)
            echo "unexpected bundle command: $*" >&2
            exit 1
            ;;
        esac
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "gem"),
      <<~BASH
        #!/usr/bin/env bash
        printf '%s\\n' "$*" >> "#{dir}/gem-install.log"
        if [[ "$1" == "install" && "$3" == bundler:* ]]; then
          version="${3#bundler:}"
          printf '%s\\n' "$version" >> "#{dir}/installed-bundlers.txt"
          exit 0
        fi

        echo "unexpected gem command: $*" >&2
        exit 1
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "yarn"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "docker"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    FileUtils.mkdir_p(File.join(dir, "scripts"))
    write_executable(
      File.join(dir, "scripts", "build-agent-image.sh"),
      <<~BASH
        #!/usr/bin/env bash
        exit 0
      BASH
    )

    script_path
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def setup_script_env(dir)
    {
      "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
      "WORKSPACE_ROOT" => File.join(dir, "workspace-root"),
      "BUNDLE_BIN_PATH" => nil,
      "BUNDLE_GEMFILE" => nil,
      "BUNDLER_SETUP" => nil,
      "BUNDLER_VERSION" => nil,
      "RUBYLIB" => nil,
      "RUBYGEMS_GEMDEPS" => nil,
      "RUBYOPT" => nil
    }
  end
end
