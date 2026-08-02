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

  def resolved_credential(project:, client:, credential: "ghp_testcredential")
    Tools::RepoWriteCredentialResolver::ResolvedCredential.new(
      client: client,
      credential: credential,
      identity: "project-token:#{project.github_token.name}"
    )
  end

  def pull_request_resource(number:, url:)
    double(number:, html_url: url)
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
