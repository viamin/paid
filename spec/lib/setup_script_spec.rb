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
    # Regression guard: docker-compose.observability.yml mounts the host
    # metrics token file into the Prometheus container at the path
    # referenced by the `paid` scrape job's authorization.credentials_file.
    # bin/setup materializes that file from the host's METRICS_TOKEN env var
    # so the value matches what docker-compose.yml propagates into the web
    # service (which the Rails side reads to decide whether to enforce auth).
    # The default location is ./tmp/prometheus/metrics_token so a live
    # token never lands in the tracked working tree.
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = setup_script_env(dir).merge("METRICS_TOKEN" => "test-scraper-token")

      Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      token_path = File.join(dir, "tmp", "prometheus", "metrics_token")
      expect(File.read(token_path)).to eq("test-scraper-token")
    end
  end

  it "tightens the metrics token file mode to owner-only so the bearer credential is not leaked on shared hosts" do
    # The metrics token is the Bearer credential Prometheus sends to
    # /api/metrics. File.write creates files with the process umask
    # (typically 022 -> 0644 on Linux), which would let another local
    # user read it on a shared dev box. bin/setup must chmod the file
    # to 0o600 after writing so only the owning user can read it.
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = setup_script_env(dir).merge("METRICS_TOKEN" => "test-scraper-token")

      Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      token_path = File.join(dir, "tmp", "prometheus", "metrics_token")
      expect(File.stat(token_path).mode & 0o777).to eq(0o600)
    end
  end

  it "creates an empty metrics token file when METRICS_TOKEN is unset so docker compose can start" do
    # When METRICS_TOKEN is absent from the process environment, bin/setup
    # still needs to ensure the token file exists because
    # `docker compose --profile observability up` refuses to start when the
    # secret source file is missing. The file must be empty so Prometheus
    # sends a blank Bearer header, which the Rails side accepts because
    # its auth check is gated on the env var.
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = setup_script_env(dir)

      Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      token_path = File.join(dir, "tmp", "prometheus", "metrics_token")
      expect(File.exist?(token_path)).to be(true)
      expect(File.read(token_path)).to eq("")
    end
  end

  it "does not overwrite an existing metrics token file when METRICS_TOKEN is unset" do
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      token_path = File.join(dir, "tmp", "prometheus", "metrics_token")
      FileUtils.mkdir_p(File.dirname(token_path))
      File.write(token_path, "bootstrap-token")
      env = setup_script_env(dir)

      Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      expect(File.read(token_path)).to eq("bootstrap-token")
    end
  end

  it "does not overwrite an existing metrics token file when METRICS_TOKEN is empty string (compose-style)" do
    # Regression guard: docker-compose.yml injects METRICS_TOKEN: ${METRICS_TOKEN:-},
    # so the variable is always present in compose environments but may be an empty
    # string when the host variable is unset. An empty value must be treated the same
    # as an absent variable so the worker's bin/setup --skip-server does not clobber
    # a token that the web/bootstrap path already materialized.
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      token_path = File.join(dir, "tmp", "prometheus", "metrics_token")
      FileUtils.mkdir_p(File.dirname(token_path))
      File.write(token_path, "bootstrap-token")
      env = setup_script_env(dir).merge("METRICS_TOKEN" => "")

      Open3.capture3(env, script_path, "--skip-server", chdir: dir)

      expect(File.read(token_path)).to eq("bootstrap-token")
    end
  end

  it "skips database preparation when --skip-database is provided" do
    Dir.mktmpdir("setup-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = setup_script_env(dir)

      stdout, stderr, status = Open3.capture3(env, script_path, "--skip-server", "--skip-database", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).not_to include("== Preparing database ==")
      database_log = File.join(dir, "database-calls.log")
      database_calls = File.exist?(database_log) ? File.read(database_log) : ""
      expect(database_calls).not_to include("ensure-worktree-databases")
      expect(database_calls).not_to include("rails db:prepare")
      expect(database_calls).not_to include("rails qdrant:check")
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
        printf 'ensure-worktree-databases\\n' >> "#{dir}/database-calls.log"
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
        printf 'rails %s\\n' "$*" >> "#{dir}/database-calls.log"
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
