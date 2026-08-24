# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GrepWorkspace do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:workspace_root) { make_workspace_root }
  let(:repo) do
    clone_repo_into_workspace(
      workspace_root:,
      repo_name: "repo-one",
      files: {
        "README.md" => "# Repo One\nhello world\n",
        "app/models/widget.rb" => "class Widget\n  def hello\n    puts \"hello\"\n  end\nend\n"
      }
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

  describe "self.available_for_chat?" do
    it "returns true when the session has a cloned workspace repo" do
      expect(described_class.available_for_chat?(user:, session:)).to be true
    end

    it "returns false when the session has no cloned repos" do
      session.update!(clone_manifest: [])
      expect(described_class.available_for_chat?(user:, session:)).to be false
    end

    it "returns false for nil user" do
      expect(described_class.available_for_chat?(user: nil, session:)).to be false
    end
  end

  describe "self.available_to?" do
    it "returns false (tool is chat-only)" do
      expect(described_class.available_to?(user:)).to be false
    end
  end

  describe "#perform" do
    it "finds matches across the cloned repo" do
      result = tool.call(repo_path: repo.fetch(:repo_path), query: "hello")

      paths = result[:matches].map { |match| match[:path] }
      expect(paths).to include("README.md", "app/models/widget.rb")
      expect(result[:truncated]).to be false
    end

    it "returns structured path/line/content for each match" do
      result = tool.call(repo_path: repo.fetch(:repo_path), query: "class Widget")

      expect(result[:matches]).to contain_exactly(
        { path: "app/models/widget.rb", line: 1, content: "class Widget" }
      )
    end

    it "scopes the search with path_filter" do
      result = tool.call(repo_path: repo.fetch(:repo_path), query: "hello", path_filter: "app/models")

      paths = result[:matches].map { |match| match[:path] }
      expect(paths.uniq).to eq([ "app/models/widget.rb" ])
    end

    it "accepts grep_repo-style path qualifiers in the query" do
      result = tool.call(repo_path: repo.fetch(:repo_path), query: "hello path:app/models")

      expect(result[:matches].map { |match| match[:path] }.uniq).to eq([ "app/models/widget.rb" ])
      expect(result[:matches]).to include(
        { path: "app/models/widget.rb", line: 2, content: "  def hello" }
      )
    end

    it "strips unsupported GitHub code-search qualifiers from the query" do
      result = tool.call(
        repo_path: repo.fetch(:repo_path),
        query: "hello repo:other/private-repo org:secret language:ruby",
        path_filter: "README.md repo:ignored/private-repo"
      )

      expect(result[:matches]).to contain_exactly(
        { path: "README.md", line: 2, content: "hello world" }
      )
    end

    it "accepts the repo root as a path_filter" do
      result = tool.call(repo_path: repo.fetch(:repo_path), query: "hello", path_filter: ".")

      paths = result[:matches].map { |match| match[:path] }
      expect(paths).to include("README.md", "app/models/widget.rb")
    end

    it "returns no matches without raising when the pattern is absent" do
      result = tool.call(repo_path: repo.fetch(:repo_path), query: "definitely_not_present_xyz")

      expect(result[:matches]).to eq([])
      expect(result[:total_matches]).to eq(0)
      expect(result[:total_count]).to eq(0)
      expect(result[:truncated]).to be false
    end

    it "requires a query" do
      expect {
        tool.call(repo_path: repo.fetch(:repo_path), query: "")
      }.to raise_error(ArgumentError, /query must be provided/)
    end

    it "rejects repo paths not present in the manifest" do
      expect {
        tool.call(repo_path: "/workspace/other-repo", query: "hello")
      }.to raise_error(ArgumentError, /clone manifest/)
    end

    it "rejects path_filter that escapes the cloned repo" do
      expect {
        tool.call(repo_path: repo.fetch(:repo_path), query: "hello", path_filter: "../escape")
      }.to raise_error(ArgumentError, /escapes the cloned repo/)
    end

    it "rejects repo paths that escape the workspace" do
      escaped_session = create(:chat_session, :workspace, account:, created_by: user, clone_manifest: [
        { project_id: project.id, path: "/workspace/../etc" }
      ])

      expect {
        described_class.new(user:, session: escaped_session).call(
          repo_path: "/workspace/../etc",
          query: "hello"
        )
      }.to raise_error(ArgumentError, /escapes the workspace/)
    end

    it "denies users without project read access" do
      other_account = create(:account)
      other_user = create(:user, :member, account: other_account)

      expect {
        described_class.new(user: other_user, session:).call(repo_path: repo.fetch(:repo_path), query: "hello")
      }.to raise_error(Pundit::NotAuthorizedError)
    end

    it "truncates output beyond MAX_OUTPUT_BYTES and flags it" do
      many_lines = Array.new(5_000) { |i| "needle occurrence #{i}\n" }.join
      File.write(File.join(repo.fetch(:host_path), "big.txt"), many_lines)
      run_cmd!("git", "-C", repo.fetch(:host_path), "add", "big.txt")
      run_cmd!("git", "-C", repo.fetch(:host_path), "commit", "-m", "add big file")

      result = tool.call(repo_path: repo.fetch(:repo_path), query: "needle")

      expect(result[:matches].length).to be <= Tools::GrepWorkspace::MAX_MATCHES
      expect(result[:truncated]).to be true
    end

    it "keeps the full match count when raw output truncates" do
      stub_const("Tools::GrepWorkspace::MAX_OUTPUT_BYTES", 256)

      many_lines = Array.new(40) { |i| "needle #{i} #{'x' * 32}\n" }.join
      File.write(File.join(repo.fetch(:host_path), "truncated-count.txt"), many_lines)
      run_cmd!("git", "-C", repo.fetch(:host_path), "add", "truncated-count.txt")
      run_cmd!("git", "-C", repo.fetch(:host_path), "commit", "-m", "add truncation fixture")

      result = tool.call(repo_path: repo.fetch(:repo_path), query: "needle")

      expect(result[:total_matches]).to eq(40)
      expect(result[:total_count]).to eq(40)
      expect(result[:truncated]).to be true
    end

    it "reports the full parsed match count even when returning only MAX_MATCHES entries" do
      many_lines = Array.new(Tools::GrepWorkspace::MAX_MATCHES + 10) { |i| "needle #{i}\n" }.join
      File.write(File.join(repo.fetch(:host_path), "many-matches.txt"), many_lines)
      run_cmd!("git", "-C", repo.fetch(:host_path), "add", "many-matches.txt")
      run_cmd!("git", "-C", repo.fetch(:host_path), "commit", "-m", "add many matches")

      result = tool.call(repo_path: repo.fetch(:repo_path), query: "needle")

      expect(result[:matches].length).to eq(Tools::GrepWorkspace::MAX_MATCHES)
      expect(result[:total_matches]).to eq(Tools::GrepWorkspace::MAX_MATCHES + 10)
      expect(result[:total_count]).to eq(Tools::GrepWorkspace::MAX_MATCHES + 10)
      expect(result[:truncated]).to be true
    end
  end
end
