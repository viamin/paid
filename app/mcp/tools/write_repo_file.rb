# frozen_string_literal: true

module Tools
  class WriteRepoFile < BaseTool
    include ContainerRepoSupport
    authorize :run_agent?, ->(args) { project_for_authorization!(args.fetch(:repo_path)) }, policy_class: ProjectPolicy

    def self.tool_name = "write_repo_file"
    def self.write_operation? = true
    def self.requires_container? = true

    def self.description
      "Write or replace a UTF-8 text file inside a cloned workspace repo."
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
          repo_path: { type: "string", description: "Workspace path of the cloned repo (for example /workspace/paid)" },
          path: { type: "string", description: "Path to write relative to the repo root" },
          content: { type: "string", description: "UTF-8 file contents (max 200KB)" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[repo_path path content confirmed]
      }
    end

    def perform(repo_path:, path:, content:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to write a repo file" unless confirmed

      context = repo_context_for!(repo_path, require_non_stale: true, policy_query: :run_agent?)
      ensure_text_payload!(content, field_name: "content")
      relative_path = write_repo_text_file!(
        repo_path: context.fetch(:repo_path),
        relative_path: path,
        content:
      )

      {
        repo_path: context.fetch(:repo_path),
        path: relative_path,
        bytes_written: content.to_s.bytesize,
        status: git_status_result(context.fetch(:repo_path)),
        diff: git_diff_result(context.fetch(:repo_path))
      }
    end
  end
end
