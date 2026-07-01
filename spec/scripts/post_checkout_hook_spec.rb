# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"
require_relative "../support/exec_tmpdir"

RSpec.describe "post-checkout hook" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  it "ensures worktree databases before running added migrations" do
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: "feature_123")
      write_git_stub(dir, previous_migrations: "", new_migrations: "db/migrate/20260630000000_create_widgets.rb")
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, "previous", "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "calls.log")).lines.map(&:chomp)).to eq([
        "ensure",
        "rails db:migrate"
      ])
    end
  end

  it "skips migrations without failing checkout when worktree database creation fails" do
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: "feature_123")
      write_git_stub(dir, previous_migrations: "", new_migrations: "db/migrate/20260630000000_create_widgets.rb")
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\nexit 1\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, "previous", "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Migration guard skipped")
      expect(File.read(File.join(dir, "calls.log")).lines.map(&:chomp)).to eq([ "ensure" ])
    end
  end

  it "does not require CREATEDB checks for the primary checkout database" do
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: nil)
      write_git_stub(dir, previous_migrations: "", new_migrations: "db/migrate/20260630000000_create_widgets.rb")
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\nexit 1\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, "previous", "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(File.read(File.join(dir, "calls.log")).lines.map(&:chomp)).to eq([ "rails db:migrate" ])
    end
  end

  def prepare_hook_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, ".githooks"))
    FileUtils.mkdir_p(File.join(dir, "bin"))
    FileUtils.mkdir_p(File.join(dir, "config"))
    FileUtils.mkdir_p(File.join(dir, "stubbin"))

    hook_path = File.join(dir, ".githooks", "post-checkout")
    FileUtils.cp(File.expand_path("../../.githooks/post-checkout", __dir__), hook_path)
    FileUtils.chmod("+x", hook_path)
    hook_path
  end

  def write_worktree_database_names(dir, suffix:)
    value = suffix.nil? ? "nil" : suffix.inspect
    File.write(File.join(dir, "config", "worktree_database_names.rb"), <<~RUBY)
      # frozen_string_literal: true

      module Paid
        module WorktreeDatabaseNames
          module_function

          def suffix
            #{value}
          end
        end
      end
    RUBY
  end

  def write_git_stub(dir, previous_migrations:, new_migrations:)
    path = File.join(dir, "stubbin", "git")
    File.write(path, <<~BASH)
      #!/usr/bin/env bash
      if [[ "$1" == "ls-tree" && "$4" == "previous" ]]; then
        printf '%s\\n' #{shellescape(previous_migrations)}
        exit 0
      fi

      if [[ "$1" == "ls-tree" && "$4" == "new" ]]; then
        printf '%s\\n' #{shellescape(new_migrations)}
        exit 0
      fi

      exit 1
    BASH
    FileUtils.chmod("+x", path)
  end

  def write_bin_stub(dir, name, body)
    path = File.join(dir, "bin", name)
    File.write(path, <<~BASH)
      #!/usr/bin/env bash
      set -euo pipefail
      #{body}
    BASH
    FileUtils.chmod("+x", path)
  end

  def base_env(dir)
    {
      "PATH" => "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}",
      "SKIP_MIGRATION_GUARD" => "0"
    }
  end

  def shellescape(value)
    Shellwords.escape(value)
  end
end
