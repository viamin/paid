# frozen_string_literal: true

module ProjectConventions
  class OpenHookGuardrailPullRequest
    Result = Struct.new(:pull_request_url, :already_configured, keyword_init: true)

    class Error < StandardError; end

    MARKER_START = "# paid hook guardrail start"
    MARKER_END = "# paid hook guardrail end"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, recommendation:)
      @project = project
      @recommendation = recommendation
      @strategy = ProjectConventions::HookGuardrailStrategy.from_recommendation(recommendation)
    end

    def call
      ensure_supported_strategy!

      worktree_service.with_temporary_worktree(project.default_branch) do |worktree_path|
        configure_commit_identity!(worktree_path)
        write_guardrail_files!(worktree_path)
        stage_guardrail_files!(worktree_path)

        if staged_files(worktree_path).empty?
          return Result.new(already_configured: true)
        end

        branch_name = push_branch!(worktree_path)
        pull_request = project.client.create_pull_request(
          project.full_name,
          base: project.default_branch,
          head: branch_name,
          title: "chore: install repo-managed commit-msg guardrail",
          body: pull_request_body
        )

        Result.new(pull_request_url: pull_request.html_url, already_configured: false)
      end
    rescue WorktreeService::Error, GithubClient::Error, Psych::Exception => e
      raise Error, e.message
    end

    private

    attr_reader :project, :recommendation, :strategy

    def ensure_supported_strategy!
      return if strategy.fetch("manager_type").in?(%w[lefthook husky githooks])

      raise Error, "This recommendation does not map to a repo-managed hook PR"
    end

    def worktree_service
      @worktree_service ||= WorktreeService.new(project)
    end

    def configure_commit_identity!(worktree_path)
      identity = Github::BotIdentity.for_git
      worktree_service.run_worktree_command(worktree_path, "config", "user.name", identity.name)
      worktree_service.run_worktree_command(worktree_path, "config", "user.email", identity.email)
    end

    def write_guardrail_files!(worktree_path)
      write_file(worktree_path, strategy.fetch("validator_path"), validator_script, executable: true)

      case strategy.fetch("manager_type")
      when "lefthook"
        write_file(worktree_path, strategy.fetch("hook_path"), lefthook_config(worktree_path))
      when "husky", "githooks"
        write_file(worktree_path, strategy.fetch("hook_path"), hook_script(worktree_path), executable: true)
      end
    end

    def stage_guardrail_files!(worktree_path)
      files_to_stage.each do |path|
        worktree_service.run_worktree_command(worktree_path, "add", "--", path)
      end
    end

    def push_branch!(worktree_path)
      branch_name = "paid/hook-guardrails-#{project.id}-#{Time.current.utc.strftime('%Y%m%d%H%M%S')}"
      worktree_service.run_worktree_command(worktree_path, "commit", "-m", "chore: install repo-managed commit-msg guardrail")
      worktree_service.run_worktree_command(worktree_path, "push", "origin", "HEAD:refs/heads/#{branch_name}")
      branch_name
    end

    def staged_files(worktree_path)
      worktree_service.run_worktree_command(worktree_path, "diff", "--cached", "--name-only").lines.map(&:strip).reject(&:blank?)
    end

    def files_to_stage
      [ strategy.fetch("validator_path"), strategy.fetch("hook_path") ]
    end

    def pull_request_body
      <<~BODY
        This PR installs a repo-managed `commit-msg` guardrail that matches the detected hook system.

        - Hook manager: #{strategy.fetch("manager_type")}
        - Allowed commit types: #{Array(strategy["allowed_types"]).join(", ")}
        - Recommendation: #{recommendation.description}
      BODY
    end

    def validator_script
      allowed = Array(strategy["allowed_types"])
      validate_allowed_types!(allowed)
      escaped_allowed = allowed.map { |type| Regexp.escape(type) }.join("|")

      <<~SH
        #!/bin/sh
        set -eu

        commit_msg_file="$1"
        first_line="$(sed -n '1p' "$commit_msg_file")"

        case "$first_line" in
          Merge\ *|Revert\ *|fixup!\ *|squash!\ *)
            exit 0
            ;;
        esac

        pattern='^(#{escaped_allowed})(\\([^)]+\\))?(!)?: .+'

        if ! printf '%s\n' "$first_line" | grep -Eq "$pattern"; then
          echo 'Commit message must follow conventional commits.' >&2
          echo 'Allowed types: #{allowed.join(", ")}' >&2
          echo 'Example: #{allowed.first}: describe the change' >&2
          exit 1
        fi
      SH
    end

    def validate_allowed_types!(allowed)
      allowed.each do |type|
        next if type.match?(/\A[a-z]+\z/)

        raise Error, "Invalid commit type in strategy: #{type.inspect}"
      end
    end

    def lefthook_config(worktree_path)
      config_path = File.join(worktree_path, strategy.fetch("hook_path"))
      config =
        if File.exist?(config_path)
          YAML.safe_load_file(config_path, permitted_classes: [ Symbol ], aliases: true) || {}
        else
          {}
        end

      commit_msg = config["commit-msg"]
      commit_msg = commit_msg.is_a?(Hash) ? commit_msg.deep_stringify_keys : {}
      commands = commit_msg["commands"]
      commands = commands.is_a?(Hash) ? commands.deep_stringify_keys : {}
      commands["paid-conventional-commits"] = {
        "run" => "#{strategy.fetch("validator_path")} {1}"
      }
      commit_msg["commands"] = commands
      config["commit-msg"] = commit_msg
      config.to_yaml
    end

    def hook_script(worktree_path)
      hook_path = File.join(worktree_path, strategy.fetch("hook_path"))
      existing = File.exist?(hook_path) ? File.read(hook_path) : default_hook_script
      block = managed_hook_block

      return existing.sub(managed_block_pattern, block) if existing.match?(managed_block_pattern)

      [ existing.rstrip, "", block ].join("\n") + "\n"
    end

    def default_hook_script
      lines = [ "#!/bin/sh" ]
      lines << '. "$(dirname -- "$0")/_/husky.sh"' if strategy.fetch("manager_type") == "husky" && strategy["husky_legacy"]
      lines.join("\n") + "\n"
    end

    def managed_hook_block
      <<~SH.chomp
        #{MARKER_START}
        repo_root="$(git rev-parse --show-toplevel)"
        "$repo_root/#{strategy.fetch("validator_path")}" "$1"
        #{MARKER_END}
      SH
    end

    def managed_block_pattern
      /#{Regexp.escape(MARKER_START)}.*?#{Regexp.escape(MARKER_END)}/m
    end

    def write_file(worktree_path, relative_path, content, executable: false)
      path = File.join(worktree_path, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      FileUtils.chmod(0o755, path) if executable
    end
  end
end
