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
      hook = hook_manager_detection
      detections << hook if hook
      ci = ci_entrypoint_detection
      detections << ci if ci
      dependency_format = dependency_format_detection
      detections << dependency_format if dependency_format
      merge_detections(detections.compact)
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
      lefthook_path = repo_file?("lefthook.yml") ? "lefthook.yml" : (repo_file?("lefthook.yaml") ? "lefthook.yaml" : nil)
      if lefthook_path
        return build_detection(
          key: "hook_manager",
          value: {
            "path" => lefthook_path,
            "required" => true,
            "type" => "lefthook"
          },
          evidence: {
            "paths" => [ lefthook_path ],
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
        /(?:Depends on|Blocked by) (?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#\d+/
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

    def merge_detections(detections)
      detections
        .group_by { |item| item[:key] }
        .values
        .map { |items| merge_detection_group(items) }
    end

    def merge_detection_group(items)
      items.reduce do |merged, item|
        merged.merge(
          confidence: [ merged[:confidence], item[:confidence] ].max,
          evidence: merge_evidence(merged[:evidence], item[:evidence])
        )
      end
    end

    def merge_evidence(left, right)
      {
        "paths" => (Array(left["paths"]) + Array(right["paths"])).uniq,
        "signals" => (Array(left["signals"]) + Array(right["signals"])).uniq
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
