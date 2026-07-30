# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GitBranchCreate do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:workspace_root) { make_workspace_root }
  let(:repo) do
    clone_repo_into_workspace(
      workspace_root:,
      repo_name: "repo-one",
      files: { "README.md" => "# Repo One\n" }
    )
  end
  let(:manifest_entry) { { project_id: project.id, path: repo.fetch(:repo_path) } }
  let(:session) do
    create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [ manifest_entry ])
  end
  let(:tool) { described_class.new(user:, session:) }

  around do |example|
    with_fake_workspace_backend(workspace_root:, container_id: session.container_id) { example.run }
  ensure
    FileUtils.rm_rf(workspace_root)
    FileUtils.rm_rf(repo[:source_path]) if repo
  end

  it "creates a branch in the cloned repo" do
    result = tool.call(repo_path: repo.fetch(:repo_path), branch_name: "feature/test-branch", confirmed: true)

    expect(run_cmd!("git", "-C", repo.fetch(:host_path), "branch", "--show-current").strip).to eq("feature/test-branch")
    expect(result[:branch_name]).to eq("feature/test-branch")
  end

  it "rejects repo path escapes" do
    expect {
      tool.call(repo_path: "../repo-one", branch_name: "feature/test", confirmed: true)
    }.to raise_error(ArgumentError, /escapes the workspace/)
  end

  it "rejects stale manifest entries" do
    session.update!(clone_manifest: [ manifest_entry.merge(stale: true) ])

    expect {
      tool.call(repo_path: repo.fetch(:repo_path), branch_name: "feature/test", confirmed: true)
    }.to raise_error(ArgumentError, /stale/)
  end

  it "rejects repo paths not present in the manifest" do
    expect {
      tool.call(repo_path: "/workspace/other-repo", branch_name: "feature/test", confirmed: true)
    }.to raise_error(ArgumentError, /clone manifest/)
  end

  it "denies viewers without a project role" do
    project # ensure the auto-owner is absorbed so the viewer is not promoted
    viewer = create(:user, :viewer, account:)
    viewer_session = create(:chat_session, :workspace, account:, created_by: viewer, clone_manifest: [ manifest_entry ])
    viewer_tool = described_class.new(user: viewer, session: viewer_session)

    expect {
      viewer_tool.call(repo_path: repo.fetch(:repo_path), branch_name: "feature/test-branch", confirmed: true)
    }.to raise_error(Pundit::NotAuthorizedError)
  end
end
