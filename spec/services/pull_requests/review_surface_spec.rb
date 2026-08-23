# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe PullRequests::ReviewSurface, :no_db do
  let(:project) { instance_double(Project, lid_mode: nil) }
  let(:agent_run) do
    instance_double(
      AgentRun,
      project: project,
      worktree_path: worktree_path,
      base_commit_sha: "base123",
      result_commit_sha: "head456"
    )
  end
  let(:worktree_path) { Dir.mktmpdir("review-surface") }
  let(:git_status) { instance_double(Process::Status, success?: true) }

  before do
    allow(Open3).to receive(:capture2).and_return([ changed_files_output, git_status ])
  end

  after do
    FileUtils.remove_entry(worktree_path)
  end

  context "with an RSpec file" do
    let(:changed_files_output) { "spec/services/projects/import_spec.rb\n" }

    before do
      FileUtils.mkdir_p(File.join(worktree_path, "spec/services/projects"))
      File.write(File.join(worktree_path, "spec/services/projects/import_spec.rb"), <<~RUBY)
        RSpec.describe Projects::Import do
          context "when the repository exists" do
            it "creates a project" do
            end

            it "records the default branch" do
            end
          end

          context "when GitHub rejects the token" do
            it "reports the authentication failure" do
            end
          end
        end
      RUBY
    end

    it "renders a documentation-style RSpec outline" do # @spec TDD-PR-003
      body = described_class.call(body: "## Summary\n\nTest PR", agent_run: agent_run)

      expect(body).to include("## Test Outline")
      expect(body).to include("Projects::Import")
      expect(body).to include("  when the repository exists")
      expect(body).to include("    creates a project")
      expect(body).to include("    records the default branch")
      expect(body).to include("  when GitHub rejects the token")
      expect(body).to include("    reports the authentication failure")
    end
  end

  context "with a non-RSpec test file" do
    let(:changed_files_output) { "test/test_importer.py\n" }

    before do
      FileUtils.mkdir_p(File.join(worktree_path, "test"))
      File.write(File.join(worktree_path, "test/test_importer.py"), <<~PYTHON)
        class TestImporter:
            def test_creates_project(self):
                pass

        def test_rejects_invalid_token():
            pass
      PYTHON
    end

    it "renders the nearest structural fallback outline" do # @spec TDD-PR-004
      body = described_class.call(body: "## Summary\n\nTest PR", agent_run: agent_run)

      expect(body).to include("## Test Outline")
      expect(body).to include("TestImporter")
      expect(body).to include("  creates project")
      expect(body).to include("test_importer.py")
      expect(body).to include("  rejects invalid token")
    end
  end

  context "when a follow-up run does not touch any test files" do
    let(:changed_files_output) { "app/services/projects/import.rb\n" }
    let(:existing_body) do
      <<~MARKDOWN
        ## Summary

        Test PR

        ## Test Outline

        ```text
        Projects::Import
          creates a project
        ```
      MARKDOWN
    end

    it "preserves the existing Test Outline section" do # @spec TDD-PR-002
      body = described_class.call(body: existing_body, agent_run: agent_run)

      expect(body).to include("## Test Outline")
      expect(body).to include("Projects::Import")
      expect(body).to include("creates a project")
    end
  end
end
