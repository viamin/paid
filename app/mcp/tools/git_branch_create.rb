# frozen_string_literal: true

module Tools
  class GitBranchCreate < BaseTool
    include ContainerRepoSupport
    authorize :run_agent?, ->(args) { project_for_authorization!(args.fetch(:repo_path)) }, policy_class: ProjectPolicy

    def self.tool_name = "git_branch_create"
    def self.write_operation? = true
    def self.requires_container? = true

    def self.description
      "Create a branch in a cloned workspace repo."
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
          repo_path: { type: "string", description: "Workspace path of the cloned repo" },
          branch_name: { type: "string", description: "Branch name to create" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[repo_path branch_name confirmed]
      }
    end

    def perform(repo_path:, branch_name:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to create a branch" unless confirmed

      context = repo_context_for!(repo_path, require_non_stale: true, policy_query: :run_agent?)
      validate_branch_name!(context.fetch(:repo_path), branch_name)

      stdout, stderr, exit_code = git_exec!("git -C #{Shellwords.escape(context.fetch(:repo_path))} switch -c #{Shellwords.escape(branch_name)}")
      raise ArgumentError, stderr.presence || stdout.presence || "Branch creation failed" unless exit_code.zero?

      {
        repo_path: context.fetch(:repo_path),
        branch_name: branch_name,
        status: git_status_result(context.fetch(:repo_path))
      }
    end

    private

    def validate_branch_name!(repo_path, branch_name)
      raise ArgumentError, "branch_name must be provided" if branch_name.to_s.strip.blank?

      stdout, stderr, exit_code = git_exec!("git -C #{Shellwords.escape(repo_path)} check-ref-format --branch #{Shellwords.escape(branch_name)}")
      raise ArgumentError, stderr.presence || stdout.presence || "Invalid branch name" unless exit_code.zero?
    end
  end
end
