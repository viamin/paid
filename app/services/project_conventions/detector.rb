# frozen_string_literal: true

module ProjectConventions
  class Detector
    RELEASE_PLEASE_CONFIG_PATH = "release-please-config.json"
    RELEASE_PLEASE_MANIFEST_PATH = ".release-please-manifest.json"
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
      config_path = RELEASE_PLEASE_CONFIG_PATH if repo_file?(RELEASE_PLEASE_CONFIG_PATH)
      manifest_path = RELEASE_PLEASE_MANIFEST_PATH if repo_file?(RELEASE_PLEASE_MANIFEST_PATH)
      workflow_matches = github_workflow_matches(/release-please/i)

      evidence_paths = [ config_path, manifest_path ].compact + workflow_matches.map { |m| m[:path] }
      return [] if evidence_paths.empty?

      evidence = {
        "paths" => evidence_paths.uniq,
        "signals" => [ "release_please" ]
      }

      config = parse_json_file(config_path) if config_path
      manifest = parse_json_file(manifest_path) if manifest_path

      packages = extract_packages(config)
      changelog_sections = extract_changelog_sections(config)
      allowed_types = changelog_sections.filter_map { |s| s["type"] }
      hidden_types = changelog_sections.select { |s| s["hidden"] == true }.filter_map { |s| s["type"] }

      release_value = {
        "type" => "release_please",
        "required" => true
      }
      release_value["packages"] = packages if config.is_a?(Hash)
      release_value["changelog_sections"] = changelog_sections if changelog_sections.any?
      release_value["manifest_present"] = true if manifest_path
      release_value["manifest_versions"] = manifest if manifest && manifest.is_a?(Hash) && manifest.any?

      commit_value = {
        "type" => "conventional_commits",
        "required" => true,
        "default_type" => "feat"
      }
      commit_value["allowed_types"] = allowed_types if allowed_types.any?
      commit_value["hidden_types"] = hidden_types if hidden_types.any?

      pr_title_value = {
        "type" => "conventional_commits",
        "required" => true,
        "significant_for_release" => true
      }

      [
        build_detection(key: "release_automation", value: release_value, evidence:),
        build_detection(key: "commit_style", value: commit_value, evidence:),
        build_detection(key: "pr_title_style", value: pr_title_value, evidence:)
      ]
    end

    def commitlint_detections
      matches = COMMITLINT_PATHS.filter { |path| repo_file?(path) }
      package_json_match = package_json_commitlint_match
      matches << "package.json" if package_json_match
      return [] if matches.empty?

      value = {
        "type" => "conventional_commits",
        "required" => true,
        "default_type" => "feat"
      }

      allowed_types = infer_commitlint_types
      value["allowed_types"] = allowed_types if allowed_types

      [
        build_detection(
          key: "commit_style",
          value:,
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

      configured_hooks_path = git_config_hooks_path
      if managed_githooks_path?(configured_hooks_path)
        return build_detection(
          key: "hook_manager",
          value: { "path" => configured_hooks_path, "required" => true, "type" => "githooks" },
          evidence: { "paths" => [ ".git/config", configured_hooks_path ].uniq, "signals" => [ "core_hooks_path" ] }
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

    def extract_packages(config)
      return [] unless config.is_a?(Hash)

      packages_hash = config["packages"]
      if packages_hash.is_a?(Hash)
        return packages_hash.filter_map do |path, pkg_config|
          next unless pkg_config.is_a?(Hash)

          entry = { "path" => path }
          entry["release_type"] = pkg_config["release-type"] if pkg_config["release-type"]
          entry
        end
      end

      root_package_entry(config)
    end

    def extract_changelog_sections(config)
      return [] unless config.is_a?(Hash)

      sections = config["changelog-sections"]
      return [] unless sections.is_a?(Array)

      sections.filter_map do |section|
        next unless section.is_a?(Hash)
        next if section["type"].nil?

        entry = { "type" => section["type"] }
        entry["section"] = section["section"] if section["section"]
        entry["hidden"] = section["hidden"] if section.key?("hidden")
        entry
      end
    end

    def infer_commitlint_types
      commitlintrc = find_commitlintrc
      config =
        if commitlintrc
          parse_json_file(commitlintrc)
        elsif package_json_commitlint_match
          parse_package_json_commitlint
        end

      return unless config.is_a?(Hash)

      allowed_types_from_commitlint_config(config)
    end

    def find_commitlintrc
      COMMITLINT_PATHS.find { |path| repo_file?(path) && path.end_with?(".json") }
    end

    def build_detection(key:, value:, evidence:, confidence: 1.0)
      {
        category: Catalog.category_for(key),
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
        merged_value = merged[:value].deep_merge(item[:value]) do |_key, left_val, right_val|
          if left_val.is_a?(Array) && right_val.is_a?(Array)
            left_val | right_val
          else
            right_val
          end
        end
        merged.merge(
          confidence: [ merged[:confidence], item[:confidence] ].max,
          evidence: merge_evidence(merged[:evidence], item[:evidence]),
          value: merged_value
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

      package_json = parse_json_file("package.json")
      return false unless package_json.is_a?(Hash)

      package_json.key?("commitlint") ||
        package_json.fetch("devDependencies", {}).key?("@commitlint/config-conventional")
    end

    def root_package_entry(config)
      return [] unless config["release-type"]

      [ { "path" => ".", "release_type" => config["release-type"] } ]
    end

    def parse_package_json_commitlint
      package_json = parse_json_file("package.json")
      return unless package_json.is_a?(Hash)

      package_json["commitlint"]
    end

    def allowed_types_from_commitlint_config(config)
      rules = config.dig("rules")
      return unless rules.is_a?(Hash)

      type_enum = rules.dig("type-enum")
      return unless type_enum.is_a?(Array)

      allowed = type_enum[2]
      allowed if allowed.is_a?(Array) && allowed.any?
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

    def parse_json_file(relative_path)
      return nil unless repo_file?(relative_path)

      JSON.parse(read_file(relative_path))
    rescue JSON::ParserError
      nil
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

    def git_config_hooks_path
      git_dir = resolved_git_dir
      return unless git_dir

      config_path = git_dir.join("config")
      return unless config_path.file?

      current_section = nil
      config_path.each_line do |line|
        stripped = line.strip
        next if stripped.start_with?("#", ";") || stripped.empty?

        if stripped.start_with?("[") && stripped.end_with?("]")
          current_section = stripped.delete_prefix("[").delete_suffix("]").downcase
          next
        end

        next unless current_section == "core"

        key, value = stripped.split("=", 2).map { |part| part&.strip }
        return value if key&.downcase == "hookspath" && value.present?
      end

      nil
    end

    def managed_githooks_path?(path)
      return false if path.blank?

      path == ".githooks" || path.start_with?(".githooks/")
    end

    def resolved_git_dir
      dot_git = repo_path.join(".git")
      return dot_git if dot_git.directory?

      return unless dot_git.file?

      target = dot_git.read.lines.first.to_s.split(":", 2).last.to_s.strip
      return if target.blank?

      path = Pathname(target)
      git_dir = path.absolute? ? path : repo_path.join(path)
      resolve_common_dir(git_dir)
    end

    def resolve_common_dir(git_dir)
      commondir_file = git_dir.join("commondir")
      return git_dir unless commondir_file.file?

      common_path = commondir_file.read.strip
      return git_dir if common_path.empty?

      git_dir.join(common_path).cleanpath
    end
  end
end
