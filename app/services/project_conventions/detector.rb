# frozen_string_literal: true

module ProjectConventions
  class Detector
    RELEASE_PLEASE_CONFIG_PATHS = %w[
      release-please-config.json
      .release-please-manifest.json
    ].freeze
    COMMITLINT_PATHS = %w[
      .commitlintrc
      .commitlintrc.json
      .commitlintrc.yml
      .commitlintrc.yaml
      commitlint.config.js
      commitlint.config.cjs
      commitlint.config.mjs
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(repo_path:)
      @repo_path = Pathname(repo_path)
    end

    def call
      detections = []
      detections.concat(release_please_detections)
      detections.concat(commitlint_detections)
      detections << hook_manager_detection if hook_manager_detection
      detections << ci_entrypoint_detection if ci_entrypoint_detection
      detections << dependency_format_detection if dependency_format_detection
      detections.compact.uniq { |item| item[:key] }
    end

    private

    attr_reader :repo_path

    def release_please_detections
      matches = RELEASE_PLEASE_CONFIG_PATHS.filter { |path| repo_file?(path) }
      workflow_matches = github_workflow_matches(/release-please/i)
      evidence_paths = matches + workflow_matches.map { |match| match[:path] }
      return [] if evidence_paths.empty?

      evidence = {
        "paths" => evidence_paths.uniq,
        "signals" => [ "release_please" ]
      }

      [
        build_detection(
          key: "release_automation",
          value: { "required" => true, "type" => "release_please" },
          evidence: evidence
        ),
        build_detection(
          key: "commit_style",
          value: { "default_type" => "feat", "required" => true, "type" => "conventional_commits" },
          evidence: evidence
        ),
        build_detection(
          key: "pr_title_style",
          value: { "required" => true, "type" => "conventional_commits" },
          evidence: evidence
        )
      ]
    end

    def commitlint_detections
      matches = COMMITLINT_PATHS.filter { |path| repo_file?(path) }
      package_json_match = package_json_commitlint_match
      matches << "package.json" if package_json_match
      return [] if matches.empty?

      [
        build_detection(
          key: "commit_style",
          value: { "default_type" => "feat", "required" => true, "type" => "conventional_commits" },
          evidence: {
            "paths" => matches.uniq,
            "signals" => [ "commitlint" ]
          },
          confidence: 0.95
        )
      ]
    end

    def hook_manager_detection
      if repo_file?("lefthook.yml") || repo_file?("lefthook.yaml")
        return build_detection(
          key: "hook_manager",
          value: {
            "path" => repo_file?("lefthook.yml") ? "lefthook.yml" : "lefthook.yaml",
            "required" => true,
            "type" => "lefthook"
          },
          evidence: {
            "paths" => [ repo_file?("lefthook.yml") ? "lefthook.yml" : "lefthook.yaml" ],
            "signals" => [ "repo_managed_hooks" ]
          }
        )
      end

      if directory_exists?(".husky")
        return build_detection(
          key: "hook_manager",
          value: { "path" => ".husky", "required" => true, "type" => "husky" },
          evidence: { "paths" => [ ".husky" ], "signals" => [ "repo_managed_hooks" ] }
        )
      end

      return unless directory_exists?(".githooks")

      build_detection(
        key: "hook_manager",
        value: { "path" => ".githooks", "required" => true, "type" => "githooks" },
        evidence: { "paths" => [ ".githooks" ], "signals" => [ "repo_managed_hooks" ] }
      )
    end

    def ci_entrypoint_detection
      return unless repo_file?("bin/ci")

      build_detection(
        key: "ci_entrypoint",
        value: { "command" => "bin/ci", "required" => true },
        evidence: { "paths" => [ "bin/ci" ], "signals" => [ "repo_ci_entrypoint" ] }
      )
    end

    def dependency_format_detection
      matched_paths = text_matches(
        %w[AGENTS.md CLAUDE.md README.md],
        /(Depends on #\d+|Blocked by [A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#\d+)/
      )
      return if matched_paths.empty?

      build_detection(
        key: "issue_dependency_format",
        value: {
          "blocked_by_prefix" => "Blocked by",
          "depends_on_prefix" => "Depends on",
          "heading" => "## Dependencies"
        },
        evidence: { "paths" => matched_paths, "signals" => [ "explicit_dependency_wording" ] },
        confidence: 0.85
      )
    end

    def build_detection(key:, value:, evidence:, confidence: 1.0)
      {
        key: key,
        confidence: confidence,
        detector_key: "project_conventions",
        evidence: evidence.deep_stringify_keys,
        value: value.deep_stringify_keys
      }
    end

    def package_json_commitlint_match
      return false unless repo_file?("package.json")

      package_json = JSON.parse(read_file("package.json"))
      package_json.key?("commitlint") ||
        package_json.fetch("devDependencies", {}).key?("@commitlint/config-conventional")
    rescue JSON::ParserError
      false
    end

    def github_workflow_matches(pattern)
      workflow_dir = repo_path.join(".github", "workflows")
      return [] unless workflow_dir.directory?

      workflow_dir.glob("*.{yml,yaml}").filter_map do |path|
        relative_path = path.relative_path_from(repo_path).to_s
        { path: relative_path } if path.read.match?(pattern)
      end
    end

    def text_matches(paths, pattern)
      paths.filter do |path|
        repo_file?(path) && read_file(path).match?(pattern)
      end
    end

    def repo_file?(relative_path)
      repo_path.join(relative_path).file?
    end

    def directory_exists?(relative_path)
      repo_path.join(relative_path).directory?
    end

    def read_file(relative_path)
      repo_path.join(relative_path).read
    end
  end
end
