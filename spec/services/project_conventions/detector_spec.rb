# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectConventions::Detector, :no_db do
  let(:repo_path) { Pathname(RSpec.current_example.metadata.fetch(:tmpdir)) }

  around do |example|
    Dir.mktmpdir do |dir|
      example.metadata[:tmpdir] = dir
      example.run
    end
  end

  def write_repo_file(relative_path, content)
    path = repo_path.join(relative_path)
    path.dirname.mkpath
    path.write(content)
  end

  it "detects release-please, conventional commit, and ci conventions" do
    write_repo_file("release-please-config.json", '{"packages":{".":{}}}')
    write_repo_file("bin/ci", "#!/usr/bin/env bash\nbundle exec rspec\n")

    detections = described_class.call(repo_path:)

    expect(detections.map { |item| item[:key] }).to include(
      "release_automation",
      "commit_style",
      "pr_title_style",
      "ci_entrypoint"
    )
    expect(detections.find { |item| item[:key] == "release_automation" }[:value]["type"]).to eq("release_please")
  end

  it "detects repo-managed hook managers" do
    write_repo_file("lefthook.yml", "pre-commit:\n  commands: {}\n")

    detection = described_class.call(repo_path:).find { |item| item[:key] == "hook_manager" }

    expect(detection[:value]).to include("type" => "lefthook", "path" => "lefthook.yml")
  end

  it "detects explicit dependency wording guidance" do
    write_repo_file("AGENTS.md", "Use Depends on #123 and Blocked by owner/repo#456")

    detection = described_class.call(repo_path:).find { |item| item[:key] == "issue_dependency_format" }

    expect(detection[:value]).to include(
      "depends_on_prefix" => "Depends on",
      "blocked_by_prefix" => "Blocked by"
    )
  end

  it "merges evidence for duplicate convention keys" do
    write_repo_file("release-please-config.json", '{"packages":{".":{}}}')
    write_repo_file("commitlint.config.js", "module.exports = {};\n")

    detection = described_class.call(repo_path:).find { |item| item[:key] == "commit_style" }

    expect(detection[:evidence]).to include(
      "paths" => contain_exactly("release-please-config.json", "commitlint.config.js"),
      "signals" => contain_exactly("release_please", "commitlint")
    )
    expect(detection[:confidence]).to eq(1.0)
  end
end
