# frozen_string_literal: true

module Tools
  class ProposePullRequest < BaseTool
    include ContainerRepoSupport

    DEPENDS_ON_REF_PATTERN = /\A[a-zA-Z0-9._-]+\/[a-zA-Z0-9._-]+\#[1-9]\d*\z/
    GITHUB_HTTPS_REMOTE_PATTERN = %r{\Ahttps://github\.com/}i
    GITHUB_SSH_REMOTE_PATTERN = /\Agit@github\.com:/i

    # Captured output of a single git push attempt.
    PushResult = Struct.new(:stdout, :stderr, :exit_code, keyword_init: true) do
      def success? = exit_code.zero?

      def message
        [ stderr, stdout ].map(&:presence).compact.join(" — ").presence || "git push failed"
      end
    end

    authorize :run_agent?, ->(args) { project_for_authorization!(args.fetch(:repo_path)) }, policy_class: ProjectPolicy

    def self.tool_name = "propose_pull_request"
    def self.write_operation? = true
    def self.requires_container? = true

    def self.description
      "Push a cloned repo branch and open a GitHub pull request."
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
          branch_name: { type: "string", description: "Existing local branch to push" },
          title: { type: "string", description: "Pull request title" },
          body: { type: "string", description: "Pull request body in Markdown" },
          depends_on: {
            type: "array",
            description: "Cross-repo PR dependencies to append using Paid syntax (owner/repo#N)",
            items: { type: "string" }
          },
          confirm_commit_first: {
            type: "boolean",
            description: "Set true to acknowledge that uncommitted local changes will not be included in the PR"
          },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[repo_path branch_name title body confirmed]
      }
    end

    # @spec CHAT-PR-PROPOSAL-001, CHAT-PR-PROPOSAL-002,
    # @spec CHAT-PR-PROPOSAL-003, CHAT-PR-PROPOSAL-004, CHAT-PR-PROPOSAL-005
    def perform(repo_path:, branch_name:, title:, body:, depends_on: [], confirm_commit_first: false, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to propose a pull request" unless confirmed

      context = repo_context_for!(repo_path, require_non_stale: true, policy_query: :run_agent?)
      validate_branch_name!(context.fetch(:repo_path), branch_name)
      ensure_text_payload!(title, field_name: "title", max_bytes: 10 * 1024)
      ensure_text_payload!(body, field_name: "body")

      dependency_refs = normalize_dependency_refs(depends_on)
      dirty_repos = dirty_repo_entries
      ensure_proposable_worktree!(
        repo_path: context.fetch(:repo_path),
        confirm_commit_first: confirm_commit_first,
        dirty_repos:
      )

      resolved = RepoWriteCredentialResolver.new(project: context.fetch(:project), user:, session:).resolve
      final_body = render_pull_request_body(body, dependency_refs)

      push_branch!(
        repo_path: context.fetch(:repo_path),
        branch_name: branch_name,
        project: context.fetch(:project),
        credential: resolved.credential,
        try_project_credential_fallback: resolved.from_user_token
      )

      pull_request = resolved.client.create_pull_request(
        context.fetch(:project).full_name,
        base: context.fetch(:project).default_branch.presence || "main",
        head: branch_name,
        title: title.to_s,
        body: final_body
      )

      record_audit_event!(
        branch_name: branch_name,
        repo_path: context.fetch(:repo_path),
        project_id: context.fetch(:project).id,
        pull_request: pull_request,
        token_identity: resolved.identity
      )

      result = {
        project_id: context.fetch(:project).id,
        repo_path: context.fetch(:repo_path),
        branch_name: branch_name,
        title: title.to_s,
        body: final_body,
        pull_request_number: pull_request.number,
        pull_request_url: pull_request.html_url,
        token_identity: resolved.identity
      }
      warnings = workspace_warnings(dirty_repos)
      result[:warnings] = warnings if warnings.any?
      result[:dirty_repos] = dirty_repos if dirty_repos.any?
      result
    end

    private

    def validate_branch_name!(repo_path, branch_name)
      raise ArgumentError, "branch_name must be provided" if branch_name.to_s.strip.blank?

      stdout, stderr, exit_code = git_exec!("git -C #{Shellwords.escape(repo_path)} check-ref-format --branch #{Shellwords.escape(branch_name)}")
      raise ArgumentError, stderr.presence || stdout.presence || "Invalid branch name" unless exit_code.zero?

      _, _, exit_code = git_exec!("git -C #{Shellwords.escape(repo_path)} show-ref --verify --quiet refs/heads/#{Shellwords.escape(branch_name)}")
      raise ArgumentError, "Branch not found: #{branch_name}" unless exit_code.zero?
    end

    def normalize_dependency_refs(depends_on)
      Array(depends_on).map(&:to_s).map(&:strip).reject(&:blank?).uniq.tap do |refs|
        invalid = refs.reject { |ref| DEPENDS_ON_REF_PATTERN.match?(ref) }
        raise ArgumentError, "depends_on entries must use owner/repo#N syntax" if invalid.any?
      end
    end

    def render_pull_request_body(body, dependency_refs)
      stripped_body = body.to_s.rstrip
      dependency_lines = dependency_refs.map { |ref| "Depends on #{ref}" }
      return stripped_body if dependency_lines.empty?
      return dependency_lines.join("\n") if stripped_body.blank?

      [ stripped_body, dependency_lines.join("\n") ].join("\n\n")
    end

    # The tool ships commits, not the live working tree. A dirty repo would
    # otherwise open a PR from stale committed state and silently omit local
    # edits, so callers must explicitly acknowledge that risk to proceed.
    def ensure_proposable_worktree!(repo_path:, confirm_commit_first:, dirty_repos:)
      dirty = dirty_repos.any? { |entry| entry["path"] == repo_path }
      return unless dirty
      return if confirm_commit_first

      raise ArgumentError, "Repo has uncommitted changes. Commit first or set confirm_commit_first=true to ship the committed branch state only."
    end

    def dirty_repo_entries
      session.clone_manifest_entries.filter_map do |entry|
        manifest_path = entry[:path].to_s
        status = git_porcelain_status(manifest_path)
        next if status.blank?

        {
          "project_id" => entry[:project_id],
          "path" => manifest_path
        }
      rescue ArgumentError
        nil
      end
    end

    def workspace_warnings(dirty_repos)
      return [] unless dirty_repos.size > 1

      [ "Multiple cloned repos have uncommitted changes; review the workspace before shipping coordinated pull requests." ]
    end

    def git_porcelain_status(repo_path)
      stdout, stderr, exit_code = git_exec!("git -C #{Shellwords.escape(repo_path)} status --porcelain --untracked-files=all")
      raise ArgumentError, stderr.presence || stdout.presence || "git status failed" unless exit_code.zero?

      stdout
    end

    # Pushes the branch, falling back through alternate credentials when the
    # primary is rejected so PR proposal does not regress app-backed projects:
    #
    # * a GitHub App installation token is rejected for pushes it lacks
    #   permission for (e.g. a change under .github/workflows/) — mirrored from
    #   WorktreeService and Containers::GitOperations, the push retries with the
    #   project's configured fallback PAT (see Project#git_push_pat_fallback?).
    # * a user token the resolver preferred may lack push access — classic PAT
    #   accessible_repositories can include repos the token can read but not
    #   push, so the project credential is retried before giving up.
    def push_branch!(repo_path:, branch_name:, project:, credential:, try_project_credential_fallback: false)
      remote_url = origin_remote_url(repo_path)
      refspec = "refs/heads/#{branch_name}:refs/heads/#{branch_name}"

      result = run_git_push(repo_path:, refspec:, push_url: authenticated_push_url(remote_url:, project:, credential:))
      return if result.success?

      retried = retry_push_with_fallbacks(
        repo_path:, refspec:, remote_url:, project:, primary_failure: result, try_project_credential_fallback:
      )
      return if retried&.success?

      raise ArgumentError, (retried || result).message
    end

    def retry_push_with_fallbacks(repo_path:, refspec:, remote_url:, project:, primary_failure:, try_project_credential_fallback:)
      candidates = fallback_push_credentials(project:, primary_failure:, try_project_credential_fallback:)
      return nil if candidates.empty?

      log_push_credential_fallback(project:)
      last = primary_failure
      candidates.each do |candidate|
        last = run_git_push(repo_path:, refspec:, push_url: authenticated_push_url(remote_url:, project:, credential: candidate))
        return last if last.success?
      end
      last
    end

    # Ordered push credentials to try after the primary is rejected. The
    # project credential comes first (general user-token rejection fallback);
    # the fallback PAT is appended only for a GitHub App permission rejection,
    # matching the rest of the app.
    def fallback_push_credentials(project:, primary_failure:, try_project_credential_fallback:)
      candidates = []
      project_credential = try_project_credential_fallback ? project.github_credential : nil
      candidates << project_credential if project_credential_useful?(project_credential:, project:, primary_failure:)
      if app_permission_rejection?(primary_failure.message) && project.git_push_pat_fallback_configured?
        candidates << project.git_push_fallback_credential
      end
      candidates
    end

    # The project credential is a meaningful push fallback only when the primary
    # was a user token. On an app-backed project it is the App installation
    # token; if the push was rejected for an App permission limit, retrying it
    # wastes an installation-token mint before the PAT fallback can succeed.
    def project_credential_useful?(project_credential:, project:, primary_failure:)
      return false if project_credential.blank?
      return false if project.github_installation_id.present? && app_permission_rejection?(primary_failure.message)

      true
    end

    def run_git_push(repo_path:, refspec:, push_url:)
      env = [ "PUSH_URL=#{push_url}" ]
      command = "git -C #{Shellwords.escape(repo_path)} push --set-upstream \"$PUSH_URL\" #{Shellwords.escape(refspec)}"
      stdout, stderr, exit_code = git_exec!(command, env:)
      PushResult.new(stdout:, stderr:, exit_code:)
    end

    def log_push_credential_fallback(project:)
      Rails.logger.info(message: "propose_pull_request.push_credential_fallback", project_id: project.id)
    end

    def app_permission_rejection?(message)
      message.to_s.include?("refusing to allow a GitHub App")
    end

    def origin_remote_url(repo_path)
      stdout, stderr, exit_code = git_exec!("git -C #{Shellwords.escape(repo_path)} remote get-url origin")
      raise ArgumentError, stderr.presence || stdout.presence || "git remote get-url failed" unless exit_code.zero?

      stdout.to_s.strip
    end

    def authenticated_push_url(remote_url:, project:, credential:)
      return remote_url unless remote_url.match?(GITHUB_HTTPS_REMOTE_PATTERN) || remote_url.match?(GITHUB_SSH_REMOTE_PATTERN)

      "https://x-access-token:#{credential}@github.com/#{project.full_name}.git"
    end

    def record_audit_event!(branch_name:, repo_path:, project_id:, pull_request:, token_identity:)
      Audit::RecordEvent.call(
        action: "propose_pull_request.executed",
        actor: user,
        subject: session,
        account: account,
        metadata: {
          branch_name: branch_name,
          repo_path: repo_path,
          project_id: project_id,
          pull_request_number: pull_request.number,
          pull_request_url: pull_request.html_url,
          session_id: session.id,
          token_identity: token_identity
        }
      )
    end
  end
end
