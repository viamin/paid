# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Lid::BuildInferenceChecklist do
  def write_file(root, relative_path, content)
    absolute_path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, content)
  end

  def git(root, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: root)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end

  let(:repo_dir) { Dir.mktmpdir("lid-checklist") }

  around do |example|
    git(repo_dir, "init")
    git(repo_dir, "config", "user.name", "Paid Test")
    git(repo_dir, "config", "user.email", "paid@example.com")
    example.run
  ensure
    FileUtils.remove_entry(repo_dir) if Dir.exist?(repo_dir)
  end

  describe ".call" do
    it "builds a checklist from inferred markers and open questions" do
      write_file(repo_dir, "docs/intent/lid/lid-design.md", <<~MARKDOWN)
        ## Decisions
      MARKDOWN
      git(repo_dir, "add", ".")
      git(repo_dir, "commit", "-m", "baseline")
      base_sha = git(repo_dir, "rev-parse", "HEAD").strip

      write_file(repo_dir, "docs/intent/lid/lid-design.md", <<~MARKDOWN)
        ## Decisions

        - The planning PR keeps inferred rationale inline [inferred]
        - Review requests replace inferred markers with authored rationale [inferred]

        ## Open Questions

        - Should comment-only feedback move to Open Questions?
      MARKDOWN

      checklist = described_class.call(worktree_path: repo_dir, base_commit_sha: base_sha)

      expect(checklist).to include("## Confirm These Inferred Decisions")
      expect(checklist).to include("`docs/intent/lid/lid-design.md`: - The planning PR keeps inferred rationale inline")
      expect(checklist).to include("replace inferred markers with authored rationale")
      expect(checklist).to include("Open question: Should comment-only feedback move to Open Questions?")
    end

    it "returns an empty string when no inferred markers or open questions changed" do
      write_file(repo_dir, "README.md", "# Example\n")
      git(repo_dir, "add", ".")
      git(repo_dir, "commit", "-m", "baseline")
      base_sha = git(repo_dir, "rev-parse", "HEAD").strip

      write_file(repo_dir, "README.md", <<~MARKDOWN)
        # Example

        ## Open Questions

        - Should unrelated docs trigger the planning checklist?
      MARKDOWN

      checklist = described_class.call(worktree_path: repo_dir, base_commit_sha: base_sha)

      expect(checklist).to eq("")
    end

    it "returns an empty string when the diff also touches non-doc files" do
      write_file(repo_dir, "docs/intent/lid/lid-design.md", <<~MARKDOWN)
        ## Decisions
      MARKDOWN
      write_file(repo_dir, "app/models/widget.rb", "class Widget\nend\n")
      git(repo_dir, "add", ".")
      git(repo_dir, "commit", "-m", "baseline")
      base_sha = git(repo_dir, "rev-parse", "HEAD").strip

      write_file(repo_dir, "docs/intent/lid/lid-design.md", <<~MARKDOWN)
        ## Decisions

        - The planning PR keeps inferred rationale inline [inferred]
      MARKDOWN
      write_file(repo_dir, "app/models/widget.rb", "class Widget\n  def call; end\nend\n")

      checklist = described_class.call(worktree_path: repo_dir, base_commit_sha: base_sha)

      expect(checklist).to eq("")
    end

    it "includes changed high-level design open questions" do
      write_file(repo_dir, "docs/high-level-design.md", <<~MARKDOWN)
        # High-Level Design
      MARKDOWN
      git(repo_dir, "add", ".")
      git(repo_dir, "commit", "-m", "baseline")
      base_sha = git(repo_dir, "rev-parse", "HEAD").strip

      write_file(repo_dir, "docs/high-level-design.md", <<~MARKDOWN)
        # High-Level Design

        ## Open Questions

        - Which adoption path should the planning PR document first?
      MARKDOWN

      checklist = described_class.call(worktree_path: repo_dir, base_commit_sha: base_sha)

      expect(checklist).to include("`docs/high-level-design.md`: Open question: Which adoption path should the planning PR document first?")
    end

    it "only includes inferred markers and open questions on changed lines" do
      write_file(repo_dir, "docs/intent/lid/lid-design.md", <<~MARKDOWN)
        ## Decisions

        - Keep the legacy inference untouched [inferred]
        - Replace inferred markers after review [inferred]

        ## Open Questions

        - Should the existing open question remain deferred?
        - Should the new audit item block merge?
      MARKDOWN
      git(repo_dir, "add", ".")
      git(repo_dir, "commit", "-m", "baseline")
      base_sha = git(repo_dir, "rev-parse", "HEAD").strip

      write_file(repo_dir, "docs/intent/lid/lid-design.md", <<~MARKDOWN)
        ## Decisions

        - Keep the legacy inference untouched [inferred]
        - Replace inferred markers after review with authored rationale [inferred]

        ## Open Questions

        - Should the existing open question remain deferred?
        - Should the new audit item block merge immediately?
      MARKDOWN

      checklist = described_class.call(worktree_path: repo_dir, base_commit_sha: base_sha)

      expect(checklist).to include("Replace inferred markers after review with authored rationale")
      expect(checklist).to include("Open question: Should the new audit item block merge immediately?")
      expect(checklist).not_to include("Keep the legacy inference untouched")
      expect(checklist).not_to include("Open question: Should the existing open question remain deferred?")
    end
  end

  describe ".docs_only_planning_pr?" do
    let(:docs_only_files) do
      [
        "docs/intent/lid/lid-design.md",
        "docs/high-level-design.md",
        "AGENTS.md"
      ]
    end

    it "derives planning-PR status from the live diff, not the PR body" do
      expect(described_class.docs_only_planning_pr?(changed_files: docs_only_files)).to be(true)
    end

    it "is false once the diff touches a non-doc file" do
      changed = docs_only_files + [ "app/models/widget.rb" ]

      expect(described_class.docs_only_planning_pr?(changed_files: changed)).to be(false)
    end

    it "is false for an empty diff" do
      expect(described_class.docs_only_planning_pr?(changed_files: [])).to be(false)
    end
  end
end
