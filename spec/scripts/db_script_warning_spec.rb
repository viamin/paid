# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/exec_tmpdir"

class DbScriptWarning
end

RSpec.describe DbScriptWarning do
  include ExecTmpdir

  it "fails when db-dump cannot re-enable RLS after dumping" do
    Dir.mktmpdir("db-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, "db-dump")
      write_stub(dir, "docker", docker_stub)
      write_stub(dir, "pg_dump", "#!/bin/sh\necho 'fake dump'\n")
      write_stub(dir, "psql", db_dump_psql_stub)

      env = base_env(dir)
      stdout, stderr, status = Open3.capture3(env, script_path, "sample.dump", chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).not_to include("Dumped paid_test data")
      expect(stderr).to include("enable failed")
      expect(stderr).to include("WARNING: failed to enable RLS on widgets")
      expect(stderr).to include("Re-enabling RLS after error")
    end
  end

  it "fails when db-restore cannot re-enable protections after restore" do
    Dir.mktmpdir("db-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, "db-restore")
      write_stub(dir, "docker", docker_stub)
      write_stub(dir, "pg_restore", "#!/bin/sh\nexit 0\n")
      write_stub(dir, "psql", db_restore_psql_stub)

      backup_path = File.join(dir, "backups", "sample.dump")
      File.write(backup_path, "backup")

      env = base_env(dir)
      stdout, stderr, status = Open3.capture3(env, script_path, "sample.dump", chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).not_to include("Restore complete")
      expect(stderr).to include("enable trigger failed")
      expect(stderr).to include("WARNING: failed to enable triggers on widgets")
      expect(stderr).to include("enable failed")
      expect(stderr).to include("WARNING: failed to enable RLS on widgets")
      expect(stderr).to include("Cleaning up after error")
    end
  end

  it "fails when db-restore cannot disable user triggers before restore" do
    Dir.mktmpdir("db-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, "db-restore")
      write_stub(dir, "docker", docker_stub)
      write_stub(dir, "pg_restore", "#!/bin/sh\nexit 0\n")
      write_stub(dir, "psql", db_restore_disable_trigger_psql_stub)

      backup_path = File.join(dir, "backups", "sample.dump")
      File.write(backup_path, "backup")

      env = base_env(dir)
      stdout, stderr, status = Open3.capture3(env, script_path, "sample.dump", chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).not_to include("Restore complete")
      expect(stderr).to include("disable trigger failed")
      expect(stderr).to include("WARNING: failed to disable triggers on widgets")
      expect(stderr).to include("Cleaning up after error")
    end
  end

  it "fails when db-regenerate cannot re-enable RLS before completion" do
    Dir.mktmpdir("db-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, "db-regenerate")
      write_stub(dir, "psql", db_regenerate_psql_stub)
      write_stub(dir, "pg_dump", "#!/bin/sh\necho 'fake dump'\n")
      write_stub(dir, "pg_restore", db_regenerate_pg_restore_stub)
      write_stub(dir, "overmind", "#!/bin/sh\nexit 1\n")
      write_bin_stub(dir, "dev", "#!/bin/sh\nexit 0\n")
      write_bin_stub(dir, "rails", "#!/bin/sh\nexit 0\n")

      env = base_env(dir)
      stdout, stderr, status = Open3.capture3(env, script_path, "--practice", chdir: dir)

      expect(status.success?).to be(false), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).not_to include("PRACTICE RUN COMPLETE")
      expect(stdout).to include("Failed to enable RLS on widgets")
      expect(stdout).to include("Script exited with error")
      expect(stdout).to include("Attempting to re-enable RLS on paid_development")
    end
  end

  def prepare_script_fixture(dir, script_name)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "bin", "lib"))
    FileUtils.mkdir_p(File.join(dir, "backups"))
    FileUtils.mkdir_p(File.join(dir, "config"))

    script_path = File.join(dir, "bin", script_name)
    FileUtils.cp(File.expand_path("../../bin/#{script_name}", __dir__), script_path)
    FileUtils.cp(File.expand_path("../../bin/lib/db_helpers.sh", __dir__), File.join(dir, "bin", "lib", "db_helpers.sh"))
    FileUtils.cp(File.expand_path("../../config/worktree_database_names.rb", __dir__), File.join(dir, "config", "worktree_database_names.rb"))
    FileUtils.chmod("+x", script_path)
    script_path
  end

  def write_stub(dir, name, contents)
    path = File.join(dir, "stubbin", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def write_bin_stub(dir, name, contents)
    path = File.join(dir, "bin", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end

  def base_env(dir)
    {
      "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
      "DB_HOST" => "localhost",
      "DB_NAME" => "paid_test",
      "DB_USER" => "paid",
      "DB_PASSWORD" => "paid",
      "PAID_DEVELOPMENT_DATABASE" => "paid_development",
      "PAID_DEVELOPMENT_CABLE_DATABASE" => "paid_development_cable"
    }
  end

  def docker_stub
    <<~SH
      #!/bin/sh
      exit 0
    SH
  end

  def db_dump_psql_stub
    <<~SH
      #!/bin/sh
      args="$*"

      case "$args" in
        *"rowsecurity = true"*)
          echo "widgets"
          ;;
        *"ENABLE ROW LEVEL SECURITY"*)
          echo "enable failed" >&2
          exit 1
          ;;
        *"FORCE ROW LEVEL SECURITY"*)
          echo "force failed" >&2
          exit 1
          ;;
      esac
    SH
  end

  def db_restore_psql_stub
    <<~SH
      #!/bin/sh
      args="$*"

      case "$args" in
        *"tablename NOT IN ('ar_internal_metadata', 'schema_migrations')"*)
          echo "widgets"
          ;;
        *"rowsecurity = true"*)
          echo "widgets"
          ;;
        *"ENABLE TRIGGER USER"*)
          echo "enable trigger failed" >&2
          exit 1
          ;;
        *"ENABLE ROW LEVEL SECURITY"*)
          echo "enable failed" >&2
          exit 1
          ;;
        *"FORCE ROW LEVEL SECURITY"*)
          echo "force failed" >&2
          exit 1
          ;;
      esac
    SH
  end

  def db_restore_disable_trigger_psql_stub
    <<~SH
      #!/bin/sh
      args="$*"

      case "$args" in
        *"tablename NOT IN ('ar_internal_metadata', 'schema_migrations')"*)
          echo "widgets"
          ;;
        *"rowsecurity = true"*)
          echo "widgets"
          ;;
        *"DISABLE TRIGGER USER"*)
          echo "disable trigger failed" >&2
          exit 1
          ;;
      esac
    SH
  end

  def db_regenerate_pg_restore_stub
    <<~SH
      #!/bin/sh
      if [ "$1" = "--list" ]; then
        i=1
        while [ "$i" -le 25 ]; do
          echo "1234; 0 0 TABLE DATA public widgets_${i} paid"
          i=$((i + 1))
        done
        exit 0
      fi

      exit 0
    SH
  end

  def db_regenerate_psql_stub
    <<~SH
      #!/bin/sh
      args="$*"

      case "$args" in
        *"SELECT 1 FROM pg_database WHERE datname = 'paid_practice'"*)
          exit 0
          ;;
        *"SELECT 1 FROM pg_database WHERE datname = 'paid_practice_cable'"*)
          exit 0
          ;;
        *"rowsecurity = true"*)
          echo "widgets"
          ;;
        *"JOIN pg_policy"*)
          echo "widgets"
          ;;
        *"tablename NOT IN ('ar_internal_metadata', 'schema_migrations')"*)
          echo "widgets"
          ;;
        *"query_to_xml"*)
          echo "widgets=1"
          ;;
        *"ENABLE ROW LEVEL SECURITY"*)
          echo "enable failed" >&2
          exit 1
          ;;
        *"FORCE ROW LEVEL SECURITY"*)
          echo "force failed" >&2
          exit 1
          ;;
      esac
    SH
  end
end
