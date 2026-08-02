# frozen_string_literal: true

require "rails_helper"

# @spec CHAT-PR-PROPOSAL-001, CHAT-PR-PROPOSAL-002, CHAT-PR-PROPOSAL-003,
# @spec CHAT-PR-PROPOSAL-004, CHAT-PR-PROPOSAL-005
RSpec.describe Tools::ProposePullRequest do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:github_client) { instance_double(GithubClient) }
  let(:workspace_root) { make_workspace_root }
  let(:repo) do
    clone_repo_into_workspace(
      workspace_root:,
      repo_name: "repo-one",
      files: { "README.md" => "# Repo One\n" }
    )
  end
  let(:session) do
    create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [ repo_manifest_entry(project:, repo:) ])
  end

  around do |example|
    with_fake_workspace_backend(workspace_root:, container_id: session.container_id) { example.run }
  ensure
    FileUtils.rm_rf(workspace_root)
    FileUtils.rm_rf(repo[:source_path]) if repo
    FileUtils.rm_rf(repo_two[:source_path]) if defined?(repo_two) && repo_two
  end

  before do
    create(:project_membership, :member, user:, project:)
    run_cmd!("git", "-C", repo.fetch(:host_path), "switch", "-c", "feature/pr-proposal")
    File.write(File.join(repo.fetch(:host_path), "README.md"), "# Repo One Updated\n")
    run_cmd!("git", "-C", repo.fetch(:host_path), "add", "README.md")
    run_cmd!("git", "-C", repo.fetch(:host_path), "commit", "-m", "Update README")
    run_cmd!("git", "-C", repo.fetch(:source_path), "config", "receive.denyCurrentBranch", "updateInstead")

    allow(Tools::RepoWriteCredentialResolver).to receive(:new).and_return(
      instance_double(Tools::RepoWriteCredentialResolver, resolve: resolved_credential(project:, client: github_client))
    )
    allow(github_client).to receive(:create_pull_request).and_return(
      pull_request_resource(number: 42, url: "https://github.com/#{project.full_name}/pull/42")
    )
  end

  describe "self.available_for_chat?" do
    # @spec CHAT-PR-PROPOSAL-001
    it "returns true when the container is ready and the session has cloned repos" do
      expect(described_class.available_for_chat?(user:, session:)).to be(true)
    end
  end

  describe "#perform" do
    # @spec CHAT-PR-PROPOSAL-001, CHAT-PR-PROPOSAL-002, CHAT-PR-PROPOSAL-004
    it "pushes the branch, opens a pull request, and returns audit metadata" do
      result = tool.call(
        repo_path: repo.fetch(:repo_path),
        branch_name: "feature/pr-proposal",
        title: "Add chat PR proposal tool",
        body: "Implements the tool.",
        depends_on: [ "viamin/agent-harness#77" ],
        confirmed: true
      )

      expect_branch_pushed(repo:, branch_name: "feature/pr-proposal")
      expect_pull_request_opened(
        github_client:,
        project:,
        title: "Add chat PR proposal tool",
        body: "Implements the tool.\n\nDepends on viamin/agent-harness#77"
      )
      expect_proposal_result(result:, repo:, project:, pr_number: 42)
      expect(AccountActivityEvent.last.metadata).to include("token_identity" => "project-token:#{project.github_token.name}", "pull_request_number" => 42)
    end

    # @spec CHAT-PR-PROPOSAL-003
    it "rejects dirty worktrees unless confirm_commit_first is explicitly true" do
      File.write(File.join(repo.fetch(:host_path), "README.md"), "# Dirty change\n")

      expect {
        tool.call(
          repo_path: repo.fetch(:repo_path),
          branch_name: "feature/pr-proposal",
          title: "Dirty tree",
          body: "Should fail",
          confirmed: true
        )
      }.to raise_error(ArgumentError, /uncommitted changes/i)
    end

    # @spec CHAT-PR-PROPOSAL-003
    it "allows explicit confirmation to ship the committed branch state while local changes remain uncommitted" do
      File.write(File.join(repo.fetch(:host_path), "README.md"), "# Dirty change\n")

      result = tool.call(
        repo_path: repo.fetch(:repo_path),
        branch_name: "feature/pr-proposal",
        title: "Committed branch only",
        body: "Ships committed state only.",
        confirm_commit_first: true,
        confirmed: true
      )

      expect(result[:pull_request_number]).to eq(42)
    end

    # @spec CHAT-PR-PROPOSAL-001
    it "rejects missing branches" do
      expect {
        tool.call(
          repo_path: repo.fetch(:repo_path),
          branch_name: "feature/missing",
          title: "Missing branch",
          body: "No branch",
          confirmed: true
        )
      }.to raise_error(ArgumentError, /Branch not found/)
    end

    # @spec CHAT-PR-PROPOSAL-001
    it "denies users who cannot run agents for the target project" do
      project
      viewer = create(:user, :viewer, account:)
      viewer_session = create(:chat_session, :workspace, account:, created_by: viewer, clone_manifest: [ repo_manifest_entry(project:, repo:) ])
      viewer_tool = described_class.new(user: viewer, session: viewer_session)

      expect {
        viewer_tool.call(
          repo_path: repo.fetch(:repo_path),
          branch_name: "feature/pr-proposal",
          title: "Denied",
          body: "Denied",
          confirmed: true
        )
      }.to raise_error(Pundit::NotAuthorizedError)
    end

    # @spec CHAT-PR-PROPOSAL-002
    context "when the App push is rejected for a missing workflow permission" do
      let(:project) { create(:project, :with_github_installation, account:) }
      let(:fallback_client) { instance_double(GithubClient) }

      before do
        fallback_token = create(:github_token, :with_workflow_scope, account: project.account)
        project.update!(git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback_token)
        allow(project).to receive_messages(
          git_push_fallback_client: fallback_client,
          client: github_client
        )
        allow(fallback_client).to receive(:create_pull_request).and_return(
          pull_request_resource(number: 42, url: "https://github.com/#{project.full_name}/pull/42")
        )
      end

      it "retries the push with the configured fallback PAT and opens the pull request" do
        result, push_envs = perform_fallback_proposal(
          tool:,
          repo:,
          project:,
          title: "Workflow change",
          body: "Updates a workflow.",
          rejection: workflow_permission_rejection
        )

        expect_workflow_permission_fallback(result:, push_envs:, project:, fallback_client:, github_client:)
      end

      context "when no fallback PAT is configured" do
        before { project.update!(git_push_pat_fallback_enabled: false) }

        it "raises the rejection without retrying" do
          tool = described_class.new(user:, session:)
          with_github_origin(repo:, full_name: project.full_name)
          rejection = "! [remote rejected] feature/pr-proposal (refusing to allow a GitHub App)"
          push_envs = script_pushes(tool:, results: [ [ "", rejection, 1 ] ])

          expect {
            tool.call(
              repo_path: repo.fetch(:repo_path),
              branch_name: "feature/pr-proposal",
              title: "Workflow change",
              body: "Updates a workflow.",
              confirmed: true
            )
          }.to raise_error(ArgumentError, /refusing to allow a GitHub App/)

          expect(push_envs.length).to eq(1)
        end
      end
    end

    # @spec CHAT-PR-PROPOSAL-001
    context "when a push failure echoes the authenticated remote URL" do
      it "redacts the credential from the raised error message" do
        tool = described_class.new(user:, session:)
        with_github_origin(repo:, full_name: project.full_name)
        rejection = "fatal: unable to access " \
                    "'https://x-access-token:ghp_testcredential@github.com/#{project.full_name}.git/': " \
                    "The requested URL returned error: 403"
        script_pushes(tool:, results: [ [ "", rejection, 1 ] ])

        expect {
          tool.call(
            repo_path: repo.fetch(:repo_path),
            branch_name: "feature/pr-proposal",
            title: "Redaction check",
            body: "Body.",
            confirmed: true
          )
        }.to raise_error(ArgumentError) { |error|
          expect(error.message).not_to include("ghp_testcredential")
          expect(error.message).to include("x-access-token:[REDACTED]@github.com")
        }
      end
    end

    # @spec CHAT-PR-PROPOSAL-002
    context "when a preferred user token is rejected at push time" do
      let(:user_client) { instance_double(GithubClient) }

      before do
        allow(Tools::RepoWriteCredentialResolver).to receive(:new).and_return(
          instance_double(
            Tools::RepoWriteCredentialResolver,
            resolve: resolved_credential(
              project:,
              client: user_client,
              credential: "ghp_usertoken",
              from_user_token: true,
              identity: "user-token:Personal"
            )
          )
        )
        allow(user_client).to receive(:create_pull_request)
        allow(project).to receive(:client).and_return(github_client)
        allow(github_client).to receive(:create_pull_request).and_return(
          pull_request_resource(number: 7, url: "https://github.com/#{project.full_name}/pull/7")
        )
      end

      it "falls back to the project credential for both push and PR creation" do
        result, push_envs = perform_fallback_proposal(
          tool:,
          repo:,
          project:,
          title: "User token fallback",
          body: "Body.",
          rejection: permission_denied_rejection
        )

        expect_user_token_fallback(result:, push_envs:, project:, github_client:)
        expect(user_client).not_to have_received(:create_pull_request)
      end
    end

    context "when multiple cloned repos have uncommitted changes" do
      let(:project_two) { create(:project, account:) }
      let!(:repo_two) do
        clone_repo_into_workspace(
          workspace_root:,
          repo_name: "repo-two",
          files: { "README.md" => "# Repo Two\n" }
        )
      end
      let(:session) do
        create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [
          repo_manifest_entry(project:, repo:),
          repo_manifest_entry(project: project_two, repo: repo_two)
        ])
      end

      before do
        create(:project_membership, :member, user:, project: project_two)
        run_cmd!("git", "-C", repo_two.fetch(:host_path), "switch", "-c", "feature/other")
        File.write(File.join(repo.fetch(:host_path), "README.md"), "# Dirty one\n")
        File.write(File.join(repo_two.fetch(:host_path), "README.md"), "# Dirty two\n")
      end

      # @spec CHAT-PR-PROPOSAL-005
      it "returns a workspace warning listing the dirty repos" do
        result = tool.call(
          repo_path: repo.fetch(:repo_path),
          branch_name: "feature/pr-proposal",
          title: "Warn on multi-repo dirtiness",
          body: "Ships committed state only.",
          confirm_commit_first: true,
          confirmed: true
        )

        expect(result[:warnings]).to include(a_string_matching(/multiple cloned repos have uncommitted changes/i))
        expect(result[:dirty_repos]).to include(
          hash_including("project_id" => project.id, "path" => repo.fetch(:repo_path)),
          hash_including("project_id" => project_two.id, "path" => repo_two.fetch(:repo_path))
        )
      end
    end

    context "when another cloned repo is not mutable for the caller" do
      let(:member) { create(:user, :viewer, account:) }
      let(:project_two) { create(:project, account:) }
      let!(:repo_two) do
        clone_repo_into_workspace(
          workspace_root:,
          repo_name: "repo-two",
          files: { "README.md" => "# Repo Two\n" }
        )
      end
      let(:session) do
        create(:chat_session, :workspace, account:, created_by: member, project:, clone_manifest: [
          repo_manifest_entry(project:, repo:),
          repo_manifest_entry(project: project_two, repo: repo_two)
        ])
      end

      before do
        create(:project_membership, :member, user: member, project:)
        run_cmd!("git", "-C", repo_two.fetch(:host_path), "switch", "-c", "feature/other")
        File.write(File.join(repo.fetch(:host_path), "README.md"), "# Dirty one\n")
        File.write(File.join(repo_two.fetch(:host_path), "README.md"), "# Dirty two\n")
      end

      # @spec CHAT-PR-PROPOSAL-003, CHAT-PR-PROPOSAL-005
      it "filters unauthorized dirty repos from warnings and results" do
        result = described_class.new(user: member, session:).call(
          repo_path: repo.fetch(:repo_path),
          branch_name: "feature/pr-proposal",
          title: "Authorized repo only",
          body: "Ships committed state only.",
          confirm_commit_first: true,
          confirmed: true
        )

        expect(result[:warnings]).to be_nil
        expect(result[:dirty_repos]).to contain_exactly(
          hash_including("project_id" => project.id, "path" => repo.fetch(:repo_path))
        )
      end
    end

    context "with coordinated cross-repo PRs" do
      let(:project_two) { create(:project, account:, owner: "viamin", repo: "agent-harness") }
      let!(:repo_two) do
        clone_repo_into_workspace(
          workspace_root:,
          repo_name: "agent-harness",
          files: { "README.md" => "# Agent Harness\n" }
        )
      end
      let(:session) do
        create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [
          repo_manifest_entry(project:, repo:),
          repo_manifest_entry(project: project_two, repo: repo_two)
        ])
      end
      let(:github_client_two) { instance_double(GithubClient) }

      before do
        create(:project_membership, :member, user:, project: project_two)
        run_cmd!("git", "-C", repo_two.fetch(:host_path), "switch", "-c", "feature/upstream")
        File.write(File.join(repo_two.fetch(:host_path), "README.md"), "# Upstream change\n")
        run_cmd!("git", "-C", repo_two.fetch(:host_path), "add", "README.md")
        run_cmd!("git", "-C", repo_two.fetch(:host_path), "commit", "-m", "Upstream change")
        run_cmd!("git", "-C", repo_two.fetch(:source_path), "config", "receive.denyCurrentBranch", "updateInstead")

        allow(Tools::RepoWriteCredentialResolver).to receive(:new) do |project:, **|
          instance_double(
            Tools::RepoWriteCredentialResolver,
            resolve: project == project_two ? resolved_credential(project: project_two, client: github_client_two, credential: "ghp_two") : resolved_credential(project:, client: github_client)
          )
        end
        allow(github_client_two).to receive(:create_pull_request).and_return(
          pull_request_resource(number: 21, url: "https://github.com/#{project_two.full_name}/pull/21")
        )
        allow(github_client).to receive(:create_pull_request).and_return(
          pull_request_resource(number: 84, url: "https://github.com/#{project.full_name}/pull/84")
        )
      end

      # @spec CHAT-PR-PROPOSAL-004
      it "writes dependency syntax that Paid's cross-repo parser resolves" do
        upstream_result = propose_upstream(repo_two:)
        dependent_result = propose_dependent(repo:, project_two:, upstream_number: upstream_result[:pull_request_number])

        downstream_issue = create_downstream_issue(
          project:,
          project_two:,
          upstream_number: upstream_result[:pull_request_number],
          dependent_result:
        )

        expect(downstream_issue.dependencies.pluck(:project_id, :github_number)).to contain_exactly([ project_two.id, upstream_result[:pull_request_number] ])
      end
    end
  end

  def tool
    described_class.new(user:, session:)
  end

  def repo_manifest_entry(project:, repo:)
    { project_id: project.id, path: repo.fetch(:repo_path) }
  end

  def resolved_credential(project:, client:, credential: "ghp_testcredential", from_user_token: false, identity: nil)
    Tools::RepoWriteCredentialResolver::ResolvedCredential.new(
      client: client,
      credential: credential,
      identity: identity || "project-token:#{project.github_token&.name || project.full_name}",
      from_user_token: from_user_token
    )
  end

  def pull_request_resource(number:, url:)
    double(number:, html_url: url)
  end

  # Points the cloned repo's origin at a github.com URL so the tool embeds the
  # active credential in the push URL (mirroring production). Local file://
  # origins ignore credentials, which would hide which token was used.
  def with_github_origin(repo:, full_name:)
    run_cmd!("git", "-C", repo.fetch(:host_path), "remote", "set-url", "origin", "https://github.com/#{full_name}.git")
  end

  # Scripts push results in order and records each push's env (which carries the
  # PUSH_URL with the embedded credential). Non-push git commands (branch
  # validation, status, remote lookup) run for real against the local repo.
  def script_pushes(tool:, results:)
    attempts = []
    original = tool.method(:git_exec!)
    allow(tool).to receive(:git_exec!) do |script, env: []|
      if script.include?(" push ")
        attempts << env
        results.shift || [ "", "", 0 ]
      else
        original.call(script, env: env)
      end
    end
    attempts
  end

  def perform_fallback_proposal(tool:, repo:, project:, title:, body:, rejection:)
    allow(tool).to receive(:project_for_manifest_entry).and_return(project)
    with_github_origin(repo:, full_name: project.full_name)
    push_envs = script_pushes(tool:, results: [ [ "", rejection, 1 ], [ "", "", 0 ] ])
    result = tool.call(
      repo_path: repo.fetch(:repo_path),
      branch_name: "feature/pr-proposal",
      title: title,
      body: body,
      confirmed: true
    )
    [ result, push_envs ]
  end

  def workflow_permission_rejection
    "! [remote rejected] feature/pr-proposal (refusing to allow a GitHub App " \
      "to create or update workflow `.github/workflows/ci.yml`)"
  end

  def permission_denied_rejection
    "! [remote rejected] feature/pr-proposal (permission denied)"
  end

  def expect_push_attempts(push_envs:, first_credential:, second_credential:)
    expect(push_envs.length).to eq(2)
    expect(push_envs.first.join).to include(first_credential)
    expect(push_envs.last.join).to include(second_credential)
  end

  def expect_successful_fallback(push_envs:, result:, project:, client:, first_credential:, second_credential:, title:, body:, pr_number:, token_identity:)
    expect_push_attempts(push_envs:, first_credential:, second_credential:)
    expect_fallback_pull_request_client(result:, client:, project:, title:, body:, pr_number:, token_identity:)
  end

  def expect_workflow_permission_fallback(result:, push_envs:, project:, fallback_client:, github_client:)
    expect_successful_fallback(
      push_envs:,
      result:,
      project:,
      client: fallback_client,
      first_credential: "ghp_testcredential",
      second_credential: project.git_push_fallback_token.token,
      title: "Workflow change",
      body: "Updates a workflow.",
      pr_number: 42,
      token_identity: "fallback-token:#{project.git_push_fallback_token.name}"
    )
    expect(github_client).not_to have_received(:create_pull_request)
  end

  def expect_user_token_fallback(result:, push_envs:, project:, github_client:)
    expect_successful_fallback(
      push_envs:,
      result:,
      project:,
      client: github_client,
      first_credential: "ghp_usertoken",
      second_credential: project.github_credential,
      title: "User token fallback",
      body: "Body.",
      pr_number: 7,
      token_identity: "project-token:#{project.github_token.name}"
    )
  end

  def expect_branch_pushed(repo:, branch_name:)
    source_ref = "refs/heads/#{branch_name}"
    expect(run_cmd!("git", "-C", repo.fetch(:source_path), "rev-parse", "--verify", source_ref).strip).not_to be_empty
  end

  def expect_pull_request_opened(github_client:, project:, title:, body:)
    expect(github_client).to have_received(:create_pull_request).with(
      project.full_name,
      base: project.default_branch,
      head: "feature/pr-proposal",
      title: title,
      body: body
    )
  end

  def expect_fallback_pull_request_client(result:, client:, project:, title:, body:, pr_number:, token_identity:)
    expect(result[:pull_request_number]).to eq(pr_number)
    expect(result[:token_identity]).to eq(token_identity)
    expect(client).to have_received(:create_pull_request).with(
      project.full_name,
      base: project.default_branch,
      head: "feature/pr-proposal",
      title: title,
      body: body
    )
  end

  def expect_proposal_result(result:, repo:, project:, pr_number:)
    expect(result).to include(
      repo_path: repo.fetch(:repo_path),
      branch_name: "feature/pr-proposal",
      pull_request_number: pr_number,
      pull_request_url: "https://github.com/#{project.full_name}/pull/#{pr_number}",
      token_identity: "project-token:#{project.github_token.name}"
    )
  end

  def create_downstream_issue(project:, project_two:, upstream_number:, dependent_result:)
    create(:issue, :pull_request, project: project_two, github_number: upstream_number, body: "Upstream body")
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: dependent_result[:pull_request_number],
      body: dependent_result[:body]
    ).tap do |downstream_issue|
      Issues::ParseDependencies.call(issue: downstream_issue)
    end
  end

  def propose_upstream(repo_two:)
    described_class.new(user:, session:).call(
      repo_path: repo_two.fetch(:repo_path),
      branch_name: "feature/upstream",
      title: "Upstream change",
      body: "Upstream body",
      confirmed: true
    )
  end

  def propose_dependent(repo:, project_two:, upstream_number:)
    described_class.new(user:, session:).call(
      repo_path: repo.fetch(:repo_path),
      branch_name: "feature/pr-proposal",
      title: "Dependent change",
      body: "Dependent body",
      depends_on: [ "#{project_two.full_name}##{upstream_number}" ],
      confirmed: true
    )
  end
end
