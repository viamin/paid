# frozen_string_literal: true

module Tools
  class RunShell < BaseTool
    include ContainerRepoSupport

    # Unlike the other repo-scoped tools, a shell command is not sandboxed to its
    # working directory: the command body can `cd` into any cloned repo in the
    # workspace container, so authorizing only the working directory's project
    # would not actually isolate access. Instead, run_shell requires the user to
    # have run_agent? on every repo in the session's clone manifest (matching
    # RDR-037's "entire workspace revalidates as mutable" gate for this tool),
    # so no cloned repo reachable from the container is outside what the user is
    # otherwise authorized to run against.
    authorize :run_agent?, ->(_args) { manifest_authorization_target }, policy_class: ProjectPolicy

    DEFAULT_TIMEOUT = 60
    MAX_TIMEOUT = 600
    MAX_OUTPUT_BYTES = 100 * 1024

    def self.tool_name = "run_shell"
    def self.write_operation? = true
    def self.requires_container? = true

    def self.description
      "Execute a shell command inside the workspace container."
    end

    def self.available_to?(user:)
      false
    end

    def self.available_for_chat?(user:, session:)
      return false unless user.present?
      return false unless tenant_shell_enabled?(session)
      return false unless container_ready?(session:)
      return false unless session.clone_manifest_entries.present?
      return false unless session.project

      all_manifest_projects_mutable?(user:, session:)
    end

    # RDR-037: run_shell is only advertised when the entire workspace (every
    # cloned repo, not just the session's primary project) is mutable for the
    # current user, because a shell command can reach any cloned repo.
    def self.all_manifest_projects_mutable?(user:, session:)
      session.clone_manifest_entries.all? do |entry|
        project = Project.find_by(id: entry[:project_id])
        project && policy_allows?(user:, record: project, query: :run_agent?, policy_class: ProjectPolicy)
      end
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          command: { type: "string", description: "Shell command to execute inside the workspace container" },
          working_dir: { type: "string", description: "Working directory for the command; must be a path under a cloned repo in the workspace (for example /workspace/paid)" },
          timeout: { type: "integer", description: "Wall-clock timeout in seconds (default 60, max 600)" },
          confirmed: { type: "boolean", description: "Must be true to execute this shell command" }
        },
        required: %w[command working_dir confirmed]
      }
    end

    def perform(command:, working_dir: nil, timeout: nil, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to execute a shell command" unless confirmed
      raise ArgumentError, "Shell execution is not enabled for this tenant" unless tenant_shell_enabled?

      validate_command!(command)

      resolved_working_dir, working_dir_project = validate_working_dir!(working_dir)

      timeout_seconds = [ (timeout.to_i.positive? ? timeout.to_i : DEFAULT_TIMEOUT), MAX_TIMEOUT ].min

      stdout, stderr, exit_code = exec_shell_command!(command, working_dir: resolved_working_dir, timeout: timeout_seconds)

      truncated_stdout, stdout_oversize = truncate_output(stdout)
      truncated_stderr, stderr_oversize = truncate_output(stderr)

      record_audit_event!(
        command:,
        working_dir: resolved_working_dir,
        exit_code:,
        project_id: working_dir_project.id
      )

      result = {
        exit_code: exit_code,
        stdout: truncated_stdout,
        stderr: truncated_stderr
      }
      result[:stdout_truncated] = true if stdout_oversize
      result[:stderr_truncated] = true if stderr_oversize
      result
    end

    private

    def tenant_shell_enabled?
      self.class.tenant_shell_enabled?(session)
    end

    def self.tenant_shell_enabled?(session)
      account = session&.account
      return false unless account

      settings = account.tenant_setting
      return false unless settings

      settings.chat_shell_enabled == true
    end

    # Resolves the manifest entry that actually contains the (realpath-resolved)
    # working directory, and returns both the validated path and the project
    # that owns it — so callers attribute execution (e.g. the audit event) to
    # the repo the command truly ran in, not to whichever repo naive path
    # matching would have guessed before symlinks are resolved.
    def validate_working_dir!(working_dir)
      raise ArgumentError, "working_dir must be provided" if working_dir.to_s.strip.empty?

      path = expand_workspace_path(working_dir)
      resolved_path = resolve_container_path(path)
      raise ArgumentError, "Path escapes the workspace: #{working_dir}" unless path_within_root?(resolved_path, workspace_root_realpath)

      manifest_entry = session.clone_manifest_entries.find do |entry|
        manifest_path = expand_workspace_path(entry[:path])
        path_within_root?(resolved_path, resolve_container_path(manifest_path))
      end

      unless manifest_entry
        raise ArgumentError, "Working directory must be under a cloned repo path in the workspace: #{path}"
      end

      [ path, project_for_manifest_entry(manifest_entry.fetch(:project_id)) ]
    end

    # Returns the first manifest project the user cannot run_agent? on, so the
    # declarative `authorize` macro raises Pundit::NotAuthorizedError against
    # it. When every manifest project is mutable, returns the first one (any
    # would pass authorization at that point).
    def manifest_authorization_target
      entries = session&.clone_manifest_entries
      raise ArgumentError, "This tool requires a chat session with cloned repos" if entries.blank?

      entries.each do |entry|
        candidate = project_for_manifest_entry(entry.fetch(:project_id))
        return candidate unless self.class.policy_allows?(user:, record: candidate, query: :run_agent?, policy_class: ProjectPolicy)
      end

      project_for_manifest_entry(entries.first.fetch(:project_id))
    end

    def validate_command!(command)
      raise ArgumentError, "command must be a non-empty string" if command.to_s.strip.empty?
    end

    def exec_shell_command!(command, working_dir:, timeout:)
      container = container_handle
      script = "cd #{Shellwords.escape(working_dir)} && #{command}"
      stdout, stderr, exit_code = Containers.backend.exec_in_container(
        container,
        [ "sh", "-lc", script ],
        user: "agent",
        wait: timeout
      )
      extend_idle_timeout!

      stdout_text, stderr_text = [ Array(stdout).join, Array(stderr).join ]
        .map { |s| s.force_encoding("UTF-8").scrub }
      [ stdout_text, stderr_text, exit_code.to_i ]
    rescue Docker::Error::DockerError => e
      raise ArgumentError, "Shell command failed: #{e.message}"
    end

    def truncate_output(output)
      text = output.to_s
      return [ text, false ] if text.bytesize <= MAX_OUTPUT_BYTES

      truncated = text.byteslice(0, MAX_OUTPUT_BYTES).scrub("")
      notice = "\n\n[Output truncated at #{MAX_OUTPUT_BYTES / 1024}KB; #{text.bytesize - MAX_OUTPUT_BYTES} bytes omitted]"
      [ truncated + notice, true ]
    end

    def record_audit_event!(command:, working_dir:, exit_code:, project_id:)
      Audit::RecordEvent.call(
        action: "run_shell.executed",
        actor: user,
        subject: session,
        account: account,
        metadata: {
          command: command,
          working_dir: working_dir,
          exit_code: exit_code,
          session_id: session.id,
          project_id: project_id
        }
      )
    end
  end
end
