# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GitDiff do
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
  let(:session) do
    create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [
      { project_id: project.id, path: repo.fetch(:repo_path) }
    ])
  end
  let(:tool) { described_class.new(user:, session:) }

  around do |example|
    with_fake_workspace_backend(workspace_root:, container_id: session.container_id) { example.run }
  ensure
    FileUtils.rm_rf(workspace_root)
    FileUtils.rm_rf(repo[:source_path]) if repo
  end

  it "returns the working-tree diff" do
    File.write(File.join(repo.fetch(:host_path), "README.md"), "# Changed\n")

    result = tool.call(repo_path: repo.fetch(:repo_path))

    expect(result[:diff]).to include("# Changed")
  end

  it "rejects repo path escapes" do
    expect {
      tool.call(repo_path: "../repo-one")
    }.to raise_error(ArgumentError, /escapes the workspace/)
  end

  it "rejects repo paths not present in the manifest" do
    expect {
      tool.call(repo_path: "/workspace/other-repo")
    }.to raise_error(ArgumentError, /clone manifest/)
  end
end
