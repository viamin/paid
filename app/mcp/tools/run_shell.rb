# frozen_string_literal: true

module Tools
  class RunShell < BaseTool
    include ContainerRepoSupport

    authorize :run_agent?, ->(_args) {
      project = session&.project
      raise ArgumentError, "Session has no project" unless project
      project
    }, policy_class: ProjectPolicy

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

      project = session.project
      return false unless project

      policy_allows?(user:, record: project, query: :run_agent?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          command: { type: "string", description: "Shell command to execute inside the workspace container" },
          working_dir: { type: "string", description: "Working directory for the command; must be a path under a cloned repo in the workspace. Defaults to /workspace." },
          timeout: { type: "integer", description: "Wall-clock timeout in seconds (default 60, max 600)" },
          confirmed: { type: "boolean", description: "Must be true to execute this shell command" }
        },
        required: %w[command confirmed]
      }
    end

    def perform(command:, working_dir: nil, timeout: nil, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to execute a shell command" unless confirmed
      raise ArgumentError, "Shell execution is not enabled for this tenant" unless tenant_shell_enabled?

      validate_command!(command)

      resolved_working_dir = if working_dir.present?
        validate_working_dir!(working_dir)
      else
        WORKSPACE_ROOT
      end

      timeout_seconds = [ (timeout.to_i.positive? ? timeout.to_i : DEFAULT_TIMEOUT), MAX_TIMEOUT ].min
      timeout_seconds = timeout_seconds.positive? ? timeout_seconds : DEFAULT_TIMEOUT

      stdout, stderr, exit_code = exec_shell_command!(command, working_dir: resolved_working_dir, timeout: timeout_seconds)

      truncated_stdout, stdout_oversize = truncate_output(stdout)
      truncated_stderr, stderr_oversize = truncate_output(stderr)

      record_audit_event!(command:, working_dir: resolved_working_dir, exit_code:)

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

    def validate_command!(command)
      raise ArgumentError, "command must be a non-empty string" if command.to_s.strip.empty?
    end

    def validate_working_dir!(working_dir)
      path = normalize_workspace_path(working_dir)
      resolved_path = resolve_container_path(path)
      manifest_paths = session.clone_manifest_entries.map { |entry| expand_workspace_path(entry[:path]) }

      unless manifest_paths.any? { |manifest_path| path_within_root?(resolved_path, resolve_container_path(manifest_path)) }
        raise ArgumentError, "Working directory must be under a cloned repo path in the workspace: #{path}"
      end

      path
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

      [ Array(stdout).join, Array(stderr).join, exit_code.to_i ]
    rescue Docker::Error::DockerError => e
      raise ArgumentError, "Shell command failed: #{e.message}"
    end

    def truncate_output(output)
      text = output.to_s
      return [ text, false ] if text.bytesize <= MAX_OUTPUT_BYTES

      truncated = text.byteslice(0, MAX_OUTPUT_BYTES)
      notice = "\n\n[Output truncated at #{MAX_OUTPUT_BYTES / 1024}KB; #{text.bytesize - MAX_OUTPUT_BYTES} bytes omitted]"
      [ truncated + notice, true ]
    end

    def record_audit_event!(command:, working_dir:, exit_code:)
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
          project_id: session.project_id
        }
      )
    end
  end
end
