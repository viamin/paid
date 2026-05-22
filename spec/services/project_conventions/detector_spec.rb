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

    expect(detection[:category]).to eq("hook_system")
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

  it "detects cross-repo depends on wording" do
    write_repo_file("AGENTS.md", "Depends on owner/repo#123")

    detection = described_class.call(repo_path:).find { |item| item[:key] == "issue_dependency_format" }

    expect(detection[:value]).to include("depends_on_prefix" => "Depends on")
  end

  it "detects same-repo blocked by wording" do
    write_repo_file("README.md", "Blocked by #42")

    detection = described_class.call(repo_path:).find { |item| item[:key] == "issue_dependency_format" }

    expect(detection[:value]).to include("blocked_by_prefix" => "Blocked by")
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

  describe "release-please config parsing" do
    it "parses package paths and release types from config" do
      config = {
        packages: {
          "." => { "release-type" => "simple" },
          "packages/foo" => { "release-type" => "node" },
          "gems/bar" => { "release-type" => "ruby" }
        }
      }.to_json
      write_repo_file("release-please-config.json", config)

      detection = described_class.call(repo_path:).find { |item| item[:key] == "release_automation" }

      expect(detection[:value]["packages"]).to contain_exactly(
        a_hash_including("path" => ".", "release_type" => "simple"),
        a_hash_including("path" => "packages/foo", "release_type" => "node"),
        a_hash_including("path" => "gems/bar", "release_type" => "ruby")
      )
    end

    it "parses changelog sections to infer commit types" do
      config = {
        packages: { "." => {} },
        "changelog-sections" => [
          { type: "feat", section: "Features" },
          { type: "fix", section: "Bug Fixes" },
          { type: "perf", section: "Performance", hidden: true }
        ]
      }.to_json
      write_repo_file("release-please-config.json", config)

      detections = described_class.call(repo_path:)
      release = detections.find { |item| item[:key] == "release_automation" }
      commit_style = detections.find { |item| item[:key] == "commit_style" }

      expect(release[:value]["changelog_sections"]).to contain_exactly(
        a_hash_including("type" => "feat", "section" => "Features"),
        a_hash_including("type" => "fix", "section" => "Bug Fixes"),
        a_hash_including("type" => "perf", "section" => "Performance", "hidden" => true)
      )
      expect(commit_style[:value]["allowed_types"]).to contain_exactly("feat", "fix", "perf")
      expect(commit_style[:value]["hidden_types"]).to contain_exactly("perf")
    end

    it "captures manifest versions" do
      write_repo_file("release-please-config.json", '{"packages":{".":{}}}')
      write_repo_file(".release-please-manifest.json", '{".":"0.45.0","packages/foo":"1.2.3"}')

      detection = described_class.call(repo_path:).find { |item| item[:key] == "release_automation" }

      expect(detection[:value]["manifest_present"]).to be(true)
      expect(detection[:value]["manifest_versions"]).to eq("." => "0.45.0", "packages/foo" => "1.2.3")
      expect(detection[:evidence]["paths"]).to include("release-please-config.json", ".release-please-manifest.json")
    end

    it "detects release-please from workflow file alone" do
      write_repo_file(".github/workflows/release-please.yml", <<~YML)
        name: Release Please
        on:
          push:
            branches: [main]
        jobs:
          release-please:
            runs-on: ubuntu-latest
            steps:
              - uses: googleapis/release-please-action@v4
      YML

      detections = described_class.call(repo_path:)

      release = detections.find { |item| item[:key] == "release_automation" }
      expect(release).not_to be_nil
      expect(release[:value]["type"]).to eq("release_please")
      expect(release[:evidence]["paths"]).to include(".github/workflows/release-please.yml")
    end

    it "handles invalid JSON in config gracefully" do
      write_repo_file("release-please-config.json", "not valid json{")

      detections = described_class.call(repo_path:)

      release = detections.find { |item| item[:key] == "release_automation" }
      expect(release).not_to be_nil
      expect(release[:value]["packages"]).to be_nil
    end

    it "handles empty packages config" do
      write_repo_file("release-please-config.json", '{"packages":{}}')

      detection = described_class.call(repo_path:).find { |item| item[:key] == "release_automation" }

      expect(detection[:value]["packages"]).to be_empty
    end
  end

  describe "PR title significance" do
    it "marks PR titles as significant for release when release-please is present" do
      write_repo_file("release-please-config.json", '{"packages":{".":{}}}')

      detection = described_class.call(repo_path:).find { |item| item[:key] == "pr_title_style" }

      expect(detection[:value]["significant_for_release"]).to be(true)
      expect(detection[:value]["type"]).to eq("conventional_commits")
    end

    it "does not mark PR titles as significant without release-please" do
      detection = described_class.call(repo_path:).find { |item| item[:key] == "pr_title_style" }

      expect(detection).to be_nil
    end
  end

  describe "commitlint detection" do
    it "detects commitlint and infers conventional commits" do
      write_repo_file(".commitlintrc.json", '{"rules":{}}')

      detection = described_class.call(repo_path:).find { |item| item[:key] == "commit_style" }

      expect(detection[:value]["type"]).to eq("conventional_commits")
      expect(detection[:confidence]).to eq(0.95)
      expect(detection[:evidence]["signals"]).to include("commitlint")
    end

    it "extracts allowed types from commitlint type-enum rule" do
      config = {
        rules: {
          "type-enum" => [ 2, "always", %w[feat fix docs chore] ]
        }
      }.to_json
      write_repo_file(".commitlintrc.json", config)

      detection = described_class.call(repo_path:).find { |item| item[:key] == "commit_style" }

      expect(detection[:value]["allowed_types"]).to contain_exactly("feat", "fix", "docs", "chore")
    end

    it "does not extract types from non-JSON commitlint configs" do
      write_repo_file("commitlint.config.js", "module.exports = { rules: {} };")

      detection = described_class.call(repo_path:).find { |item| item[:key] == "commit_style" }

      expect(detection[:value]).not_to have_key("allowed_types")
    end

    it "detects commitlint via package.json devDependencies" do
      write_repo_file("package.json", '{"devDependencies":{"@commitlint/config-conventional":"^17.0.0"}}')

      detection = described_class.call(repo_path:).find { |item| item[:key] == "commit_style" }

      expect(detection).not_to be_nil
      expect(detection[:evidence]["paths"]).to include("package.json")
    end
  end

  describe "hook system detection" do
    it "detects lefthook" do
      write_repo_file("lefthook.yml", "pre-commit:\n  commands: {}\n")

      detection = described_class.call(repo_path:).find { |item| item[:key] == "hook_manager" }

      expect(detection[:value]).to include("type" => "lefthook", "path" => "lefthook.yml")
    end

    it "detects lefthook.yaml variant" do
      write_repo_file("lefthook.yaml", "pre-commit:\n  commands: {}\n")

      detection = described_class.call(repo_path:).find { |item| item[:key] == "hook_manager" }

      expect(detection[:value]).to include("type" => "lefthook", "path" => "lefthook.yaml")
    end

    it "detects husky" do
      write_repo_file(".husky/pre-commit", "#!/bin/sh\n")

      detection = described_class.call(repo_path:).find { |item| item[:key] == "hook_manager" }

      expect(detection[:value]).to include("type" => "husky", "path" => ".husky")
    end

    it "detects .githooks directory" do
      write_repo_file(".githooks/pre-commit", "#!/bin/sh\n")

      detection = described_class.call(repo_path:).find { |item| item[:key] == "hook_manager" }

      expect(detection[:value]).to include("type" => "githooks", "path" => ".githooks")
    end

    it "prefers lefthook over husky over githooks" do
      write_repo_file("lefthook.yml", "pre-commit:\n  commands: {}\n")
      write_repo_file(".husky/pre-commit", "#!/bin/sh\n")
      write_repo_file(".githooks/pre-commit", "#!/bin/sh\n")

      detection = described_class.call(repo_path:).find { |item| item[:key] == "hook_manager" }

      expect(detection[:value]["type"]).to eq("lefthook")
    end

    it "returns no hook detection when no hook manager is present" do
      detection = described_class.call(repo_path:).find { |item| item[:key] == "hook_manager" }

      expect(detection).to be_nil
    end
  end

  describe "non-release-please fallback" do
    it "detects conventions from commitlint alone without release-please" do
      write_repo_file(".commitlintrc.json", '{"rules":{"type-enum":[2,"always",["feat","fix"]]}}')
      write_repo_file("lefthook.yml", "pre-commit:\n  commands: {}\n")

      detections = described_class.call(repo_path:)

      expect(detections.map { |item| item[:key] }).not_to include("release_automation")
      commit_style = detections.find { |item| item[:key] == "commit_style" }
      expect(commit_style[:value]["type"]).to eq("conventional_commits")
      expect(commit_style[:value]["allowed_types"]).to contain_exactly("feat", "fix")
      expect(commit_style[:confidence]).to eq(0.95)
    end
  end

  describe "agent-harness-style monorepo" do
    let(:monorepo_release_please_config) do
      {
        packages: {
          "." => { "release-type" => "simple" },
          "packages/agent-harness" => { "release-type" => "ruby" },
          "packages/paid" => { "release-type" => "simple" }
        },
        "changelog-sections" => [
          { type: "feat", section: "Features" },
          { type: "fix", section: "Bug Fixes" },
          { type: "docs", section: "Documentation", hidden: true }
        ]
      }.to_json
    end

    it "detects multi-package release-please with per-package release types" do
      write_repo_file("release-please-config.json", monorepo_release_please_config)
      write_repo_file(".release-please-manifest.json", '{"." :"1.0.0","packages/agent-harness":"2.3.4","packages/paid":"0.45.0"}')

      detections = described_class.call(repo_path:)
      release = detections.find { |item| item[:key] == "release_automation" }
      commit_style = detections.find { |item| item[:key] == "commit_style" }
      pr_title = detections.find { |item| item[:key] == "pr_title_style" }

      expect(release[:value]["packages"].length).to eq(3)
      expect(release[:value]["packages"]).to include(
        a_hash_including("path" => "packages/agent-harness", "release_type" => "ruby")
      )
      expect(release[:value]["manifest_versions"]).to include("packages/agent-harness" => "2.3.4")
      expect(commit_style[:value]["allowed_types"]).to contain_exactly("feat", "fix", "docs")
      expect(commit_style[:value]["hidden_types"]).to contain_exactly("docs")
      expect(pr_title[:value]["significant_for_release"]).to be(true)
    end
  end

  describe "value merging across detectors" do
    it "deep-merges commit_style values from release-please and commitlint" do
      config = {
        packages: { "." => {} },
        "changelog-sections" => [
          { type: "feat", section: "Features" },
          { type: "fix", section: "Bug Fixes" },
          { type: "perf", section: "Performance Improvements" }
        ]
      }.to_json
      write_repo_file("release-please-config.json", config)
      write_repo_file(".commitlintrc.json", '{"rules":{"type-enum":[2,"always",["feat","fix","custom"]]}}')

      detection = described_class.call(repo_path:).find { |item| item[:key] == "commit_style" }

      expect(detection[:value]["type"]).to eq("conventional_commits")
      expect(detection[:value]["allowed_types"]).to contain_exactly("feat", "fix", "perf", "custom")
      expect(detection[:confidence]).to eq(1.0)
      expect(detection[:evidence]["signals"]).to contain_exactly("release_please", "commitlint")
    end
  end
end
