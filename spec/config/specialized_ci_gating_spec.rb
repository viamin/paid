# frozen_string_literal: true

require "spec_helper"
require "psych"
require "pathname"
require "tmpdir"
require "open3"
require "fileutils"

class SpecializedCiGating < Pathname
end

RSpec.describe SpecializedCiGating, :no_db do
  let(:workflow) { Psych.safe_load_file(File.expand_path("../../.github/workflows/ci.yml", __dir__)) }
  let(:lint) { workflow.fetch("jobs").fetch("lint") }
  let(:detect_script) { lint.fetch("steps").find { |step| step["id"] == "specialized_changes" }.fetch("run") }

  def git!(directory, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", directory, *args)
    raise stderr unless status.success?

    stdout.strip
  end

  def classify(paths, event: "pull_request", base: nil)
    Dir.mktmpdir("specialized-ci") do |directory|
      git!(directory, "init", "-q")
      FileUtils.mkdir_p(File.join(directory, "db/migrate"))
      File.write(File.join(directory, "db/migrate/base.rb"), "base")
      git!(directory, "add", "db/migrate/base.rb")
      git!(directory, "-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", "base")
      base_sha = git!(directory, "rev-parse", "HEAD")
      paths.each do |path|
        destination = File.join(directory, path)
        FileUtils.mkdir_p(File.dirname(destination))
        File.write(destination, "changed")
        git!(directory, "add", "--", path)
      end
      git!(directory, "-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", "head", "--allow-empty")
      yield directory if block_given?
      output = File.join(directory, "outputs")
      env = { "BASE_SHA" => base || base_sha, "HEAD_SHA" => "HEAD", "EVENT_NAME" => event, "GITHUB_OUTPUT" => output }
      _stdout, _stderr, status = Open3.capture3(env, "bash", "-e", "-o", "pipefail", "-c", detect_script, chdir: directory)
      [ File.exist?(output) ? File.read(output) : "", status.success? ]
    end
  end

  # @spec SPECIALIZED-CI-001
  {
    "docs/guide.md" => %w[false false false],
    "spec/models/project_spec.rb" => %w[false false false],
    "app/models/project.rb" => %w[true false true],
    "app/views/projects/show.html.erb" => %w[true false true],
    "db/migrate/example.rb" => %w[true true true],
    "config/routes.rb" => %w[true true true],
    "lib/runtime.rb" => %w[true true true],
    "Gemfile.lock" => %w[true true true],
    "package.json" => %w[true true true],
    ".github/workflows/ci.yml" => %w[true true true],
    "docs/api/openapi.yaml" => %w[true false false],
    "docs/api/pacts/example.json" => %w[true false false],
    ".github/schemathesis-constraints.txt" => %w[true false false],
    "scripts/performance/benchmark.rb" => %w[false false true],
    "docs/performance/baseline.json" => %w[false false true],
    "spec/performance/queries_spec.rb" => %w[false false true]
  }.each do |path, expected|
    it "selects the specialized jobs affected by #{path}" do
      output, success = classify([ path ])
      expect(success).to be(true)
      expect(output.lines.map { |line| line.strip.split("=").last }).to eq(expected)
    end
  end

  # @spec SPECIALIZED-CI-002
  it "selects every job for main pushes without PR diff metadata" do
    output, success = classify([], event: "push", base: "unavailable")
    expect(success).to be(true)
    expect(output).to eq("contracts_changed=true\nmigrations_changed=true\nperformance_changed=true\n")
  end

  # @spec SPECIALIZED-CI-003
  it "fails when the PR diff cannot be read" do
    output, success = classify([], base: "unavailable")
    expect(success).to be(false)
    expect(output).to be_empty
  end

  # @spec SPECIALIZED-CI-003
  it "treats unusual filenames as data" do
    output, success = classify([ "docs/$(touch unexpected)\napp/models/example.rb" ])
    expect(success).to be(true)
    expect(output).to eq("contracts_changed=false\nmigrations_changed=false\nperformance_changed=false\n")
  end

  # @spec SPECIALIZED-CI-003
  it "selects migration checks when a migration is deleted" do
    output, success = classify([]) do |directory|
      git!(directory, "rm", "db/migrate/base.rb")
      git!(directory, "-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", "delete")
    end
    expect(success).to be(true)
    expect(output).to include("migrations_changed=true")
  end

  # @spec SPECIALIZED-CI-003
  it "includes the old side of a rename out of a selected directory" do
    output, success = classify([]) do |directory|
      git!(directory, "mv", "db/migrate/base.rb", "renamed.rb")
      git!(directory, "-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", "rename")
    end
    expect(success).to be(true)
    expect(output).to include("migrations_changed=true")
  end

  # @spec SPECIALIZED-CI-003
  it "includes earlier commits in the complete PR diff" do
    output, success = classify([ "db/migrate/example.rb" ]) do |directory|
      File.write(File.join(directory, "README.md"), "later docs change")
      git!(directory, "add", "README.md")
      git!(directory, "-c", "user.name=CI", "-c", "user.email=ci@example.test", "commit", "-qm", "docs")
    end
    expect(success).to be(true)
    expect(output).to include("migrations_changed=true")
  end

  # @spec SPECIALIZED-CI-004
  it "gates specialized services on lint outputs while retaining the trusted-author gate" do
    %w[pact-provider-verification schemathesis migrations performance].each do |name|
      job = workflow.fetch("jobs").fetch(name)
      output = %w[pact-provider-verification schemathesis].include?(name) ? "contracts" : name
      expect(job.fetch("needs")).to eq("lint")
      expect(job.fetch("if")).to include("needs.lint.outputs.#{output}_changed == 'true'", "github.event_name != 'pull_request'", "author_association", "paid-agents[bot]")
    end
    expect(lint.fetch("outputs").keys).to include("contracts_changed", "migrations_changed", "performance_changed")
  end
end
