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

  it "warns when db-dump cannot toggle RLS on a table" do
    Dir.mktmpdir("db-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, "db-dump")
      write_stub(dir, "docker", docker_stub)
      write_stub(dir, "pg_dump", "#!/bin/sh\necho 'fake dump'\n")
      write_stub(dir, "psql", db_dump_psql_stub)

      env = base_env(dir)
      stdout, stderr, status = Open3.capture3(env, script_path, "sample.dump", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Dumped paid_test data")
      expect(stderr).to include("disable failed")
      expect(stderr).to include("WARNING: failed to disable RLS on widgets")
      expect(stderr).to include("WARNING: 1 table(s) failed while attempting to disable RLS")
      expect(stderr).to include("enable failed")
      expect(stderr).to include("WARNING: failed to enable RLS on widgets")
      expect(stderr).to include("force failed")
      expect(stderr).to include("WARNING: failed to force RLS on widgets")
    end
  end

  it "warns when db-restore cannot re-enable protections on a table" do
    Dir.mktmpdir("db-script-spec", exec_tmpdir) do |dir|
      script_path = prepare_script_fixture(dir, "db-restore")
      write_stub(dir, "docker", docker_stub)
      write_stub(dir, "pg_restore", "#!/bin/sh\nexit 0\n")
      write_stub(dir, "psql", db_restore_psql_stub)

      backup_path = File.join(dir, "backups", "sample.dump")
      File.write(backup_path, "backup")

      env = base_env(dir)
      stdout, stderr, status = Open3.capture3(env, script_path, "sample.dump", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Restore complete")
      expect(stderr).to include("enable trigger failed")
      expect(stderr).to include("WARNING: failed to enable triggers on widgets")
      expect(stderr).to include("enable failed")
      expect(stderr).to include("WARNING: failed to enable RLS on widgets")
      expect(stderr).to include("force failed")
      expect(stderr).to include("WARNING: failed to force RLS on widgets")
    end
  end

  def prepare_script_fixture(dir, script_name)
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "backups"))

    script_path = File.join(dir, "bin", script_name)
    FileUtils.cp(File.expand_path("../../bin/#{script_name}", __dir__), script_path)
    FileUtils.chmod("+x", script_path)
    script_path
  end

  def write_stub(dir, name, contents)
    path = File.join(dir, "stubbin", name)
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
      "DB_PASSWORD" => "paid"
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
        *"DISABLE ROW LEVEL SECURITY"*)
          echo "disable failed" >&2
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
        *"DISABLE ROW LEVEL SECURITY"*)
          echo "disable failed" >&2
          exit 1
          ;;
        *"DISABLE TRIGGER ALL"*)
          echo "disable trigger failed" >&2
          exit 1
          ;;
        *"ENABLE TRIGGER ALL"*)
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
end
