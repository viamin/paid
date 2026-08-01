# frozen_string_literal: true

require "shellwords"

module Tools
  class CloneProject < BaseTool
    authorize :show?, ->(args) { policy_scope(Project).find(args.fetch(:project_id)) }

    CLONE_TIMEOUT = 120

    def self.tool_name = "clone_project"
    def self.write_operation? = true
    def self.requires_container? = true

    def self.description
      "Clone a GitHub project into the workspace container at /workspace/<project-slug>/."
    end

    def self.available_to?(user:)
      false
    end

    def self.available_for_chat?(user:, session:)
      user.present? && container_ready?(session:)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID to clone" },
          confirmed: { type: "boolean", description: "Must be true to execute this clone operation" }
        },
        required: %w[project_id confirmed]
      }
    end

    def perform(project_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to clone a project" unless confirmed

      ensure_container_ready!

      project = policy_scope(Project).find(project_id)
      authorize(project, :show?, policy_class: ProjectPolicy)

      enforce_clone_limit!

      existing = session.clone_manifest.find { |entry| entry.project_id == project.id }
      if existing
        return already_cloned_result(project, existing)
      end

      token, identity = resolve_clone_token(project)
      slug = project_slug(project)
      repo_path = "/workspace/#{slug}"

      execute_clone!(project, token, repo_path)

      cloned_at = Time.current
      session.append_clone_manifest_entry(
        project_id: project.id,
        cloned_at: cloned_at,
        path: repo_path,
        token_identity: identity
      )
      session.save!

      {
        repo_path: repo_path,
        project_id: project.id,
        project_slug: slug,
        token_identity: identity,
        cloned_at: cloned_at.iso8601,
        status: "cloned"
      }
    end

    private

    def ensure_container_ready!
      raise ArgumentError, "This tool requires a running workspace container" if session.blank?
      raise ArgumentError, "This tool requires a running workspace container" if session.container_id.blank?
    end

    def enforce_clone_limit!
      max_repos = session.account.tenant_setting&.chat_max_cloned_repos || 5
      if session.clone_manifest.size >= max_repos
        raise ArgumentError, "Maximum cloned repos limit reached (#{max_repos}). Remove a repo before cloning another."
      end
    end

    def already_cloned_result(project, entry)
      {
        repo_path: entry.path,
        project_id: project.id,
        project_slug: project_slug(project),
        token_identity: entry.token_identity,
        cloned_at: entry.cloned_at&.iso8601,
        status: "already_cloned"
      }
    end

    def resolve_clone_token(project)
      resolver = RepoReadClientResolver.new(project:, user:, session:)
      resolved = resolver.resolve

      identity = resolved.identity
      token = if identity.start_with?("user-token:")
        token_name = identity.sub("user-token:", "")
        user_token = user.created_github_tokens.active.find_by(name: token_name)
        user_token&.token
      end

      unless token.present?
        gh_token = project.github_token
        token = gh_token.token if gh_token&.active?
      end

      raise ArgumentError, "Project #{project.full_name} has no active GitHub token; cannot clone" if token.blank?

      [ token, identity ]
    end

    def execute_clone!(project, token, repo_path)
      clone_url = "https://x-access-token:$CLONE_TOKEN@github.com/#{project.full_name}.git"
      clone_cmd = "mkdir -p #{Shellwords.escape(repo_path)} && git clone --depth 1 #{Shellwords.escape(clone_url)} #{Shellwords.escape(repo_path)} 2>&1"

      timeout = session.account.tenant_setting&.chat_clone_timeout || CLONE_TIMEOUT

      container = Containers.backend.get_container(session.container_id)
      container.refresh! if container.respond_to?(:refresh!)

      result = Containers.backend.exec_in_container(
        container,
        [ "sh", "-c", clone_cmd ],
        wait: timeout,
        Env: [ "CLONE_TOKEN=#{token}" ]
      )

      exit_code = if result.is_a?(Array)
        result[2]
      else
        -1
      end

      return if exit_code == 0

      output = result.is_a?(Array) ? result[0..1].flatten.join("\n").truncate(500) : ""
      raise ArgumentError, "Clone failed (exit #{exit_code}): #{output}"
    end

    def project_slug(project)
      project.full_name.tr("/", "-")
    end
  end
end
