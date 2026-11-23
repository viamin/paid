# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "shellwords"
require "tmpdir"
require_relative "../support/exec_tmpdir"

RSpec.describe "post-checkout hook" do # rubocop:disable RSpec/DescribeClass
  include ExecTmpdir

  def null_ref
    "0" * 40
  end

  it "ensures worktree databases before running added migrations" do # @spec DEVELOPER-MIGRATION-GUARD-001
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

  it "skips migrations without failing checkout when worktree database creation fails" do # @spec DEVELOPER-MIGRATION-GUARD-001
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

  it "does not require CREATEDB checks for the primary checkout database" do # @spec DEVELOPER-MIGRATION-GUARD-001
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

  it "runs no Rails or database commands for a new-worktree null previous ref" do # @spec DEVELOPER-MIGRATION-GUARD-002
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: "acceptance_27f")
      write_git_stub(dir, previous_migrations: "", new_migrations: "db/migrate/20260630000000_create_widgets.rb")
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, null_ref, "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("new-worktree")
      expect(hook_calls(dir)).to be_empty
    end
  end

  it "runs no Rails or database commands for an empty previous ref" do # @spec DEVELOPER-MIGRATION-GUARD-002
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: "acceptance_27f")
      write_git_stub(dir, previous_migrations: "", new_migrations: "db/migrate/20260630000000_create_widgets.rb")
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, "", "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("new-worktree")
      expect(hook_calls(dir)).to be_empty
    end
  end

  it "runs no Rails or database commands when the previous ref does not resolve" do # @spec DEVELOPER-MIGRATION-GUARD-003
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: "feature_123")
      write_git_stub(dir,
                     previous_migrations: nil,
                     new_migrations: "db/migrate/20260630000000_create_widgets.rb",
                     resolvable_refs: [ "new" ])
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, "previous", "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("skipping")
      expect(hook_calls(dir)).to be_empty
    end
  end

  it "runs no Rails or database commands when the new ref does not resolve" do # @spec DEVELOPER-MIGRATION-GUARD-003
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: "feature_123")
      write_git_stub(dir,
                     previous_migrations: "db/migrate/20260630000000_create_widgets.rb",
                     new_migrations: nil,
                     resolvable_refs: [ "previous" ])
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, "previous", "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("skipping")
      expect(hook_calls(dir)).to be_empty
    end
  end

  it "runs no Rails or database commands when the previous migration tree cannot be read" do # @spec DEVELOPER-MIGRATION-GUARD-004
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: "feature_123")
      write_git_stub(dir,
                     previous_migrations: nil,
                     new_migrations: "db/migrate/20260630000000_create_widgets.rb")
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      stdout, stderr, status = Open3.capture3(base_env(dir), hook_path, "previous", "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("skipping")
      expect(hook_calls(dir)).to be_empty
    end
  end

  it "skips when the migration guard override is set" do # @spec DEVELOPER-MIGRATION-GUARD-005
    Dir.mktmpdir("post-checkout-hook-spec", exec_tmpdir) do |dir|
      hook_path = prepare_hook_fixture(dir)
      write_worktree_database_names(dir, suffix: "feature_123")
      write_git_stub(dir, previous_migrations: "", new_migrations: "db/migrate/20260630000000_create_widgets.rb")
      write_bin_stub(dir, "ensure-worktree-databases", "printf 'ensure\\n' >> #{shellescape(File.join(dir, 'calls.log'))}\n")
      write_bin_stub(dir, "rails", "printf 'rails %s\\n' \"$*\" >> #{shellescape(File.join(dir, 'calls.log'))}\n")

      env = base_env(dir).merge("SKIP_MIGRATION_GUARD" => "1")
      stdout, stderr, status = Open3.capture3(env, hook_path, "previous", "new", "1", chdir: dir)

      expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(hook_calls(dir)).to be_empty
    end
  end

  def hook_calls(dir)
    path = File.join(dir, "calls.log")
    return [] unless File.exist?(path)

    File.read(path).lines.map(&:chomp)
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

  def write_git_stub(dir, previous_migrations:, new_migrations:, resolvable_refs: %w[previous new])
    known_refs = (resolvable_refs || []).map { |ref| shellescape(ref.to_s) }.join(" ")
    path = File.join(dir, "stubbin", "git")
    File.write(path, <<~BASH)
      #!/usr/bin/env bash
      if [[ "$1" == "rev-parse" && "$2" == "--verify" ]]; then
        for known in #{known_refs}; do
          if [[ "$4" == "$known"^* ]]; then
            exit 0
          fi
        done
        exit 1
      fi

      if [[ "$1" == "ls-tree" && "$4" == "previous" ]]; then
        #{ls_tree_body(previous_migrations)}
      fi

      if [[ "$1" == "ls-tree" && "$4" == "new" ]]; then
        #{ls_tree_body(new_migrations)}
      fi

      exit 1
    BASH
    FileUtils.chmod("+x", path)
  end

  def ls_tree_body(migrations)
    return "echo 'fatal: bad object' >&2\nexit 1" if migrations.nil?

    "printf '%s\\n' #{shellescape(migrations)}\nexit 0"
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
