# frozen_string_literal: true

require "erb"
require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../support/exec_tmpdir"

class DatabaseYmlErb
end

RSpec.describe DatabaseYmlErb do
  include ExecTmpdir

  around do |example|
    original_env = ENV.to_hash
    %w[
      PAID_DEVELOPMENT_DATABASE
      PAID_DEVELOPMENT_CABLE_DATABASE
      PAID_TEST_DATABASE
      PAID_WORKTREE_DB_SUFFIX
    ].each { |key| ENV.delete(key) }
    example.run
  ensure
    ENV.replace(original_env)
  end

  it "renders shared database names for a primary checkout" do
    rendered = Dir.mktmpdir("database-yml-erb-spec", exec_tmpdir) do |dir|
      prepare_fixture(dir)
      render_fixture(dir)
    end

    expect(rendered).to include("database: paid_development")
    expect(rendered).to include("database: paid_development_cable")
    expect(rendered).to include("database: paid_test")
  end

  it "renders branch-specific database names for a linked worktree checkout" do
    rendered = Dir.mktmpdir("database-yml-erb-spec", exec_tmpdir) do |dir|
      prepare_fixture(dir, linked_worktree: true)
      render_fixture(dir)
    end

    expect(rendered).to include("database: paid_development_feature_pay_1940_")
    expect(rendered).to include("database: paid_development_cable_feature_pay_1940_")
    expect(rendered).to include("database: paid_test_feature_pay_1940_")
  end

  it "pins only primary and test tasks to DATABASE_URL" do # @spec RAILS-CONTROL-PLANE-013
    database_url = "postgres://agent:agent@primary:5432/paid_test"
    rendered = Dir.mktmpdir("database-yml-erb-spec", exec_tmpdir) do |dir|
      prepare_fixture(dir)
      render_fixture(dir, "DATABASE_URL" => database_url)
    end
    configuration = YAML.safe_load(rendered, aliases: true)

    expect(configuration.dig("development", "primary", "url")).to eq(database_url)
    expect(configuration.dig("development", "cable")).not_to have_key("url")
    expect(configuration.dig("test", "url")).to eq(database_url)
  end

  def prepare_fixture(dir, linked_worktree: false)
    FileUtils.mkdir_p(File.join(dir, "config"))
    FileUtils.cp(File.expand_path("../../config/database.yml", __dir__), File.join(dir, "config", "database.yml"))
    FileUtils.cp(File.expand_path("../../config/worktree_database_names.rb", __dir__), File.join(dir, "config", "worktree_database_names.rb"))
    return unless linked_worktree

    FileUtils.mkdir_p(File.join(dir, "stubbin"))
    write_executable(
      File.join(dir, "stubbin", "git"),
      <<~BASH
        #!/usr/bin/env bash
        if [[ "$1" == "rev-parse" && "$2" == "--abbrev-ref" && "$3" == "HEAD" ]]; then
          echo "feature/PAY-1940"
          exit 0
        fi

        if [[ "$1" == "rev-parse" && "$2" == "--absolute-git-dir" ]]; then
          echo "#{dir}/.git/worktrees/feature-pay-1940"
          exit 0
        fi

        exit 1
      BASH
    )
    File.write(File.join(dir, ".git"), "gitdir: #{dir}/.git/worktrees/feature-pay-1940\n")
    ENV["PATH"] = "#{File.join(dir, 'stubbin')}:#{ENV.fetch('PATH')}"
  end

  def render_fixture(dir, env = {})
    stdout, stderr, status = Open3.capture3(
      { "PATH" => ENV.fetch("PATH"), **env },
      "ruby",
      "-rerb",
      "-e",
      "puts ERB.new(File.read('config/database.yml')).result",
      chdir: dir
    )

    expect(status.success?).to be(true), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
    stdout
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod("+x", path)
  end
end
