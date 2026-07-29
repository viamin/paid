# frozen_string_literal: true

module Tools
  class ApplyPatch < BaseTool
    include ContainerRepoSupport
    authorize :show?, ->(args) { project_for_authorization!(args.fetch(:repo_path)) }, policy_class: ProjectPolicy

    DIFF_PATH_PATTERNS = [
      /\Adiff --git a\/(?<from>.+) b\/(?<to>.+)\z/,
      /\A(?:---|\+\+\+) [ab]\/(?<path>.+)\z/,
      /\A(?:rename|copy) (?:from|to) (?<path>.+)\z/
    ].freeze
    BINARY_PATCH_MARKERS = [
      /\AGIT binary patch\z/,
      /\ABinary files .* differ\z/
    ].freeze

    def self.tool_name = "apply_patch"
    def self.write_operation? = true
    def self.requires_container? = true

    def self.description
      "Apply a unified diff inside a cloned workspace repo."
    end

    def self.available_to?(user:)
      false
    end

    def self.available_for_chat?(user:, session:)
      user.present? && container_ready?(session:) && session.clone_manifest_entries.present?
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          repo_path: { type: "string", description: "Workspace path of the cloned repo" },
          patch: { type: "string", description: "Unified diff to apply (max 200KB)" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[repo_path patch confirmed]
      }
    end

    def perform(repo_path:, patch:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to apply a patch" unless confirmed

      context = repo_context_for!(repo_path, require_non_stale: true)
      ensure_text_payload!(patch, field_name: "patch")
      reject_binary_patch_payload!(patch)
      validate_patch_paths!(context.fetch(:repo_path), patch)

      env = [ encode_env("PATCH_B64", patch) ]
      check_script = %(printf %s "$PATCH_B64" | base64 -d | git -C #{Shellwords.escape(context.fetch(:repo_path))} apply --check -)
      stdout, stderr, exit_code = git_exec!(check_script, env:)
      raise ArgumentError, stderr.presence || stdout.presence || "Patch check failed" unless exit_code.zero?

      apply_script = %(printf %s "$PATCH_B64" | base64 -d | git -C #{Shellwords.escape(context.fetch(:repo_path))} apply -)
      stdout, stderr, exit_code = git_exec!(apply_script, env:)
      raise ArgumentError, stderr.presence || stdout.presence || "Patch apply failed" unless exit_code.zero?

      {
        repo_path: context.fetch(:repo_path),
        status: git_status_result(context.fetch(:repo_path)),
        diff: git_diff_result(context.fetch(:repo_path))
      }
    end

    private

    def reject_binary_patch_payload!(patch)
      patch.each_line do |line|
        stripped = line.strip
        next if stripped.blank?

        raise ArgumentError, "patch contains a binary diff hunk" if BINARY_PATCH_MARKERS.any? { |marker| marker.match?(stripped) }
      end
    end

    def validate_patch_paths!(repo_path, patch)
      touched_paths = patch.each_line.filter_map do |line|
        stripped = line.strip
        next if stripped.blank?
        next if stripped.end_with?("/dev/null")

        match = DIFF_PATH_PATTERNS.lazy.map { |pattern| stripped.match(pattern) }.find(&:present?)
        next unless match

        match.names.filter_map { |name| match[name.to_sym] }.compact
      end.flatten.uniq

      touched_paths.each do |relative_path|
        normalize_repo_relative_path(repo_path, relative_path)
      end
    end
  end
end
