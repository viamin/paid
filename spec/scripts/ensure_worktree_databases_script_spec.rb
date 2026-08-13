# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

class EnsureWorktreeDatabasesScript
end

RSpec.describe EnsureWorktreeDatabasesScript do
  include ExecTmpdir

  it "rejects invalid explicit database names before querying Postgres" do
    Dir.mktmpdir("ensure-worktree-databases-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = base_env(dir).merge(
        "PAID_DEVELOPMENT_DATABASE" => "x'; DROP DATABASE paid_production; --"
      )

      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stderr).to include("Invalid database name")
      expect(stderr).to include("PAID_DEVELOPMENT_DATABASE")
      expect(File.exist?(File.join(dir, "psql-invoked.log"))).to be(false)
    end
  end

  it "rejects invalid role names before creating databases" do
    Dir.mktmpdir("ensure-worktree-databases-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir)
      env = base_env(dir).merge("DB_USERNAME" => "paid\" SUPERUSER --")

      stdout, stderr, status = Open3.capture3(env, script_path, chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stderr).to include("Invalid role name")
      expect(stderr).to include("DB_USERNAME / DB_USER")
      expect(File.exist?(File.join(dir, "psql-invoked.log"))).to be(false)
    end
  end

  it "succeeds without creator privileges when all worktree databases already exist" do
    Dir.mktmpdir("ensure-worktree-databases-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, psql_stub: existing_databases_psql_stub(dir))

      stdout, stderr, status = Open3.capture3(base_env(dir), script_path, chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Worktree databases already exist.")
      expect(File.read(File.join(dir, "psql-queries.log"))).to include("SELECT 1 FROM pg_database")
      expect(File.read(File.join(dir, "psql-queries.log"))).not_to include("SELECT rolcreatedb")
    end
  end

  def prepare_script_fixture(dir, psql_stub: default_psql_stub(dir))
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "config"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    script_path = File.join(dir, "bin", "ensure-worktree-databases")
    FileUtils.cp(File.expand_path("../../bin/ensure-worktree-databases", __dir__), script_path)
    FileUtils.cp(File.expand_path("../../config/worktree_database_names.rb", __dir__), File.join(dir, "config", "worktree_database_names.rb"))
    FileUtils.chmod("+x", script_path)

    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        if [[ "$1" == "rev-parse" && "$2" == "--abbrev-ref" ]]; then
          echo "feature/test"
          exit 0
        fi

        if [[ "$1" == "rev-parse" && "$2" == "--absolute-git-dir" ]]; then
          echo "#{dir}/.git/worktrees/test"
          exit 0
        fi

        exit 1
      BASH
    )

    write_executable(
      File.join(dir, "stubbin", "psql"),
      psql_stub
    )

    File.write(File.join(dir, ".git"), "gitdir: #{dir}/.git/worktrees/test\n")

    script_path
  end

  def base_env(dir)
    {
      "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
      "DATABASE_URL" => "",
      "DB_HOST" => "localhost",
      "DB_PASSWORD" => "paid"
    }
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def default_psql_stub(dir)
    <<~BASH
      #!/usr/bin/env bash
      echo invoked > "#{dir}/psql-invoked.log"
      exit 0
    BASH
  end

  def existing_databases_psql_stub(dir)
    <<~BASH
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "#{dir}/psql-queries.log"

      case "$*" in
        *"SELECT 1 FROM pg_database WHERE datname = '"*)
          echo 1
          exit 0
          ;;
        *"SELECT rolcreatedb FROM pg_roles WHERE rolname = current_user"*)
          echo "creator check should not run" >&2
          exit 1
          ;;
      esac

      exit 1
    BASH
  end
end
