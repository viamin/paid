# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::WriteRepoFile do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:session) do
    create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [
      { project_id: project.id, path: repo.fetch(:repo_path) }
    ])
  end
  let(:tool) { described_class.new(user:, session:) }
  let(:workspace_root) { make_workspace_root }
  let(:repo) do
    clone_repo_into_workspace(
      workspace_root:,
      repo_name: "repo-one",
      files: { "README.md" => "# Repo One\n" }
    )
  end

  around do |example|
    with_fake_workspace_backend(workspace_root:, container_id: session.container_id) { example.run }
  ensure
    FileUtils.rm_rf(workspace_root)
    FileUtils.rm_rf(repo[:source_path]) if repo
  end

  it "writes a file inside the cloned repo" do
    result = tool.call(
      repo_path: repo.fetch(:repo_path),
      path: "lib/feature.txt",
      content: "hello\n",
      confirmed: true
    )

    expect(File.read(File.join(repo.fetch(:host_path), "lib/feature.txt"))).to eq("hello\n")
    expect(result[:status]).to include("?? lib/feature.txt")
    expect(result[:diff]).to include("hello")
  end

  it "rejects repo-relative path escapes" do
    expect {
      tool.call(repo_path: repo.fetch(:repo_path), path: "../escape.txt", content: "x", confirmed: true)
    }.to raise_error(ArgumentError, /escapes the cloned repo/)
  end

  it "rejects writes through symlinked directories that point outside the repo" do
    FileUtils.ln_s(Dir.tmpdir, File.join(repo.fetch(:host_path), "outside"))

    expect {
      tool.call(repo_path: repo.fetch(:repo_path), path: "outside/escape.txt", content: "x", confirmed: true)
    }.to raise_error(ArgumentError, /escapes the cloned repo/)
  end

  it "rejects writes to a symlinked target file" do
    external_target = File.join(Dir.mktmpdir("chat-external-target"), "escape.txt")
    FileUtils.mkdir_p(File.dirname(external_target))
    File.write(external_target, "outside\n")
    FileUtils.ln_s(external_target, File.join(repo.fetch(:host_path), "linked.txt"))

    expect {
      tool.call(repo_path: repo.fetch(:repo_path), path: "linked.txt", content: "x", confirmed: true)
    }.to raise_error(ArgumentError, /escapes the cloned repo/)
  ensure
    FileUtils.rm_rf(File.dirname(external_target))
  end

  it "rejects symlinked repo paths that resolve outside the workspace" do
    external_repo = Dir.mktmpdir("chat-external-repo")
    create_git_repo(external_repo, "README.md" => "# External Repo\n")
    FileUtils.ln_s(external_repo, File.join(workspace_root, "outside-repo"))

    escaped_session = create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [
      { project_id: project.id, path: "/workspace/outside-repo" }
    ])

    expect {
      described_class.new(user:, session: escaped_session).call(
        repo_path: "/workspace/outside-repo",
        path: "lib/file.txt",
        content: "x",
        confirmed: true
      )
    }.to raise_error(ArgumentError, /escapes the workspace/)
  ensure
    FileUtils.rm_rf(external_repo)
  end

  it "rejects oversized content" do
    expect {
      tool.call(repo_path: repo.fetch(:repo_path), path: "big.txt", content: "x" * (201 * 1024), confirmed: true)
    }.to raise_error(ArgumentError, /size limit/)
  end

  it "rejects binary content" do
    expect {
      tool.call(repo_path: repo.fetch(:repo_path), path: "bad.bin", content: "\x00abc".b, confirmed: true)
    }.to raise_error(ArgumentError, /binary/)
  end

  it "rejects repo paths not present in the manifest" do
    expect {
      tool.call(repo_path: "/workspace/other-repo", path: "lib/file.txt", content: "x", confirmed: true)
    }.to raise_error(ArgumentError, /clone manifest/)
  end
end
