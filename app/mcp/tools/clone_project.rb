# frozen_string_literal: true

require "shellwords"

module Tools
  class CloneProject < BaseTool
    include ContainerRepoSupport

    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }

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
      user.present?
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

    # @spec clone_project returns already_cloned for manifest entries even when the session is at capacity.
    # @spec clone_project uses the resolved project GitHub credential, including GitHub App tokens, for clones.
    def perform(project_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to clone a project" unless confirmed

      ensure_container_ready!

      project = project_for(project_id)

      existing = session.clone_manifest.find { |entry| entry.project_id == project.id }
      if existing
        return already_cloned_result(project, existing)
      end

      enforce_clone_limit!

      token, identity = resolve_clone_token(project)
      slug = project_slug(project)
      repo_path = "/workspace/#{slug}"

      execute_clone!(project, token, repo_path)

      cloned_at = Time.current
      session.append_clone_manifest_entry(
        project_id: project.id,
        cloned_at: cloned_at,
        path: repo_path,
        token_identity: identity,
        project_name: project.name,
        project_full_name: project.full_name,
        status: "ready",
        stale: false
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
      resolved =
        begin
          RepoReadClientResolver.new(project:, user:, session:).resolve
        rescue ArgumentError
          nil
        end

      token = resolved&.credential
      identity = resolved&.identity

      raise ArgumentError, "Project #{project.full_name} has no active GitHub token; cannot clone" if token.blank?

      [ token, identity ]
    end

    def execute_clone!(project, token, repo_path)
      # `$CLONE_TOKEN` is a literal placeholder expanded by the shell at runtime
      # (the secret is passed via the Env entry below, never inlined). Only the
      # user/org-controlled `full_name` and the repo path are escaped — escaping
      # the whole URL would turn `$CLONE_TOKEN` into `\$CLONE_TOKEN` and the
      # shell would pass the literal placeholder instead of the token.
      escaped_full_name = Shellwords.escape(project.full_name)
      escaped_path = Shellwords.escape(repo_path)
      clone_cmd = "git clone --depth 1 https://x-access-token:$CLONE_TOKEN@github.com/#{escaped_full_name}.git #{escaped_path} 2>&1"

      timeout = session.account.tenant_setting&.chat_clone_timeout || CLONE_TIMEOUT

      container = container_handle

      result = Containers.backend.exec_in_container(
        container,
        [ "sh", "-c", clone_cmd ],
        user: "agent",
        wait: timeout,
        Env: [ "CLONE_TOKEN=#{token}" ]
      )

      # The clone is the longest-running container op (up to chat_clone_timeout).
      # Reset the session idle clock afterwards — like git_exec! does for every
      # other container tool — so a session near its idle deadline is not reaped
      # before the next tool runs.
      extend_idle_timeout!

      exit_code = if result.is_a?(Array)
        result[2]
      else
        -1
      end

      return if exit_code == 0

      # Redact before surfacing: a failed clone can echo the authenticated URL
      # (e.g. `https://x-access-token:<token>@github.com/...`) in stderr.
      raw_output = result.is_a?(Array) ? result[0..1].flatten.join("\n") : ""
      cleanup_partial_clone!(escaped_path)
      raise ArgumentError, "Clone failed (exit #{exit_code}): #{redact_clone_output(raw_output, token).truncate(500)}"
    rescue Docker::Error::DockerError => e
      # A timeout or exec error can leave a partial /workspace/<slug> behind.
      # Remove it so a retry clones into a clean directory instead of failing
      # with "destination path already exists and is not an empty directory".
      cleanup_partial_clone!(escaped_path)
      raise ArgumentError, "Workspace command failed: #{e.message}"
    end

    # Removes a partially-cloned repo directory so a subsequent retry succeeds.
    # Best-effort: any error here must not mask the original clone failure.
    def cleanup_partial_clone!(escaped_path)
      Containers.backend.exec_in_container(
        container_handle,
        [ "sh", "-c", "rm -rf #{escaped_path}" ],
        user: "agent",
        wait: 30
      )
    rescue StandardError
      # Swallowed deliberately — see method comment.
    end

    def redact_clone_output(output, token)
      redacted = output.to_s.dup
      redacted.gsub!(token, "[REDACTED]") if token.present?
      redacted.gsub!(%r{x-access-token:[^@/\s]+@github\.com}, "x-access-token:[REDACTED]@github.com")
      redacted
    end

    def project_slug(project)
      project.full_name.tr("/", "-")
    end

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end
  end
end
