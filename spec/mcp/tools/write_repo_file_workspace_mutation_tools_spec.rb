# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::WriteRepoFile do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project_one) { create(:project, account:) }
  let(:project_two) { create(:project, account:) }
  let(:workspace_root) { make_workspace_root }

  around do |example|
    with_fake_workspace_backend(workspace_root:, container_id: session.container_id) { example.run }
  ensure
    FileUtils.rm_rf(workspace_root)
    FileUtils.rm_rf(repo_one[:source_path]) if defined?(repo_one) && repo_one
    FileUtils.rm_rf(repo_two[:source_path]) if defined?(repo_two) && repo_two
  end

  context "with one cloned repo" do
    let!(:repo_one) do
      clone_repo_into_workspace(
        workspace_root:,
        repo_name: "repo-one",
        files: { "README.md" => "# Repo One\n" }
      )
    end
    let(:session) do
      create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [
        { project_id: project_one.id, path: repo_one.fetch(:repo_path) }
      ])
    end

    it "writes a file and then shows it in git diff" do
      write_result = described_class.new(user:, session:).call(
        repo_path: repo_one.fetch(:repo_path),
        path: "app/new_file.rb",
        content: "class NewFile\nend\n",
        confirmed: true
      )
      diff_result = Tools::GitDiff.new(user:, session:).call(repo_path: repo_one.fetch(:repo_path))

      expect(write_result[:status]).to include("?? app/new_file.rb")
      expect(diff_result[:diff]).to include("class NewFile")
    end
  end

  context "with two cloned repos" do
    let!(:repo_one) do
      clone_repo_into_workspace(
        workspace_root:,
        repo_name: "repo-one",
        files: { "README.md" => "# Repo One\n" }
      )
    end
    let!(:repo_two) do
      clone_repo_into_workspace(
        workspace_root:,
        repo_name: "repo-two",
        files: { "README.md" => "# Repo Two\n" }
      )
    end
    let(:session) do
      create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [
        { project_id: project_one.id, path: repo_one.fetch(:repo_path) },
        { project_id: project_two.id, path: repo_two.fetch(:repo_path) }
      ])
    end

    it "keeps writes isolated to the targeted repo" do
      described_class.new(user:, session:).call(
        repo_path: repo_one.fetch(:repo_path),
        path: "lib/one.txt",
        content: "one\n",
        confirmed: true
      )
      described_class.new(user:, session:).call(
        repo_path: repo_two.fetch(:repo_path),
        path: "lib/two.txt",
        content: "two\n",
        confirmed: true
      )

      diff_one = Tools::GitDiff.new(user:, session:).call(repo_path: repo_one.fetch(:repo_path))
      diff_two = Tools::GitDiff.new(user:, session:).call(repo_path: repo_two.fetch(:repo_path))

      expect(diff_one[:diff]).to include("one")
      expect(diff_one[:diff]).not_to include("two")
      expect(diff_two[:diff]).to include("two")
      expect(diff_two[:diff]).not_to include("one")
    end
  end
end
