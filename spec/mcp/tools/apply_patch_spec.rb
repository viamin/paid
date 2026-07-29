# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ApplyPatch do
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

  it "applies a unified diff inside the cloned repo" do
    patch = <<~PATCH
      diff --git a/README.md b/README.md
      --- a/README.md
      +++ b/README.md
      @@ -1 +1 @@
      -# Repo One
      +# Updated Repo One
    PATCH

    result = tool.call(repo_path: repo.fetch(:repo_path), patch:, confirmed: true)

    expect(File.read(File.join(repo.fetch(:host_path), "README.md"))).to include("Updated Repo One")
    expect(result[:status]).to include("M README.md")
    expect(result[:diff]).to include("Updated Repo One")
  end

  it "rejects patch paths that escape the repo" do
    patch = <<~PATCH
      diff --git a/../hack.txt b/../hack.txt
      --- a/../hack.txt
      +++ b/../hack.txt
      @@ -0,0 +1 @@
      +owned
    PATCH

    expect {
      tool.call(repo_path: repo.fetch(:repo_path), patch:, confirmed: true)
    }.to raise_error(ArgumentError, /escapes the cloned repo/)
  end

  it "rejects oversized patch content" do
    expect {
      tool.call(repo_path: repo.fetch(:repo_path), patch: "x" * (201 * 1024), confirmed: true)
    }.to raise_error(ArgumentError, /size limit/)
  end

  it "rejects binary patch content" do
    expect {
      tool.call(repo_path: repo.fetch(:repo_path), patch: "\x00diff".b, confirmed: true)
    }.to raise_error(ArgumentError, /binary/)
  end

  it "rejects repo paths not present in the manifest" do
    expect {
      tool.call(repo_path: "/workspace/other-repo", patch: "", confirmed: true)
    }.to raise_error(ArgumentError, /clone manifest/)
  end
end
