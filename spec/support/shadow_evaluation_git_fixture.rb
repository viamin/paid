# frozen_string_literal: true

require "open3"

# Test helper for specs exercising IntentConformance::ShadowEvaluationLedgerGitEvidence,
# which verifies a shadow-evaluation ledger against real Git history rather than
# caller-supplied labels. Builds a throwaway git repository per example so tests
# never touch the host repository's own history.
module ShadowEvaluationGitFixture
  GIT_ENV = {
    "GIT_AUTHOR_NAME" => "Shadow Evaluation Spec", "GIT_AUTHOR_EMAIL" => "shadow-eval@example.com",
    "GIT_COMMITTER_NAME" => "Shadow Evaluation Spec", "GIT_COMMITTER_EMAIL" => "shadow-eval@example.com"
  }.freeze

  def init_git_repo(dir)
    run_git(dir, "init", "-q")
  end

  # Writes content to path, stages, and commits it, returning the new commit SHA.
  def git_write!(dir, path, content, message)
    File.write(path, content)
    commit_file!(dir, path, message)
  end

  # Appends events (one JSON object per line) to an existing ledger file and
  # commits the append, returning the new commit SHA.
  def git_append_events!(dir, path, events, message)
    File.open(path, "a") do |file|
      file.puts unless File.zero?(path) || File.binread(path).end_with?("\n")
      events.each { |event| file.puts(JSON.generate(event)) }
    end
    commit_file!(dir, path, message)
  end

  def commit_file!(dir, path, message)
    run_git(dir, "add", "--", File.basename(path))
    run_git(dir, "commit", "-q", "-m", message)
    run_git(dir, "rev-parse", "HEAD").strip
  end

  def run_git(dir, *args)
    stdout, stderr, status = Open3.capture3(GIT_ENV, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end

RSpec.configure { |config| config.include ShadowEvaluationGitFixture, :no_db }
