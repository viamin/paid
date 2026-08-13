# frozen_string_literal: true

module Tools
  class GitDiff < BaseTool
    include ContainerRepoSupport
    authorize :show?, ->(args) { project_for_authorization!(args.fetch(:repo_path)) }, policy_class: ProjectPolicy

    def self.tool_name = "git_diff"
    def self.requires_container? = true

    def self.description
      "Show the working-tree diff for a cloned workspace repo."
    end

    def self.available_to?(user:)
      false
    end

    def self.available_for_chat?(user:, session:)
      user.present? && session&.clone_manifest_entries.present?
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          repo_path: { type: "string", description: "Workspace path of the cloned repo" }
        },
        required: %w[repo_path]
      }
    end

    def perform(repo_path:)
      context = repo_context_for!(repo_path)

      {
        repo_path: context.fetch(:repo_path),
        diff: git_diff_result(context.fetch(:repo_path))
      }
    end
  end
end
