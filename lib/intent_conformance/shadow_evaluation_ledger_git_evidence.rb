# frozen_string_literal: true

require "digest"
require "open3"
require "pathname"

module IntentConformance
  # Binds a shadow-evaluation ledger to real, repository-visible Git history.
  #
  # ShadowEvaluationLedger#ensure_manifest_predates_events! only compares the
  # caller-supplied manifest_commit label across events — a cheap sanity check,
  # but not proof that the manifest actually predates the events. An operator
  # could otherwise append the whole freeze/adjudication/shadow-run sequence in
  # one sitting, backdate recorded_at, and pass any existing commit SHA as
  # manifest_commit. This module closes that gap by asking Git itself: does
  # manifest_commit really contain the frozen manifest, and did each descendant
  # commit append exactly one ledger event? Comparing each commit's ledger
  # snapshot with its parent rejects historical rewrites and deletions, which
  # current-line blame cannot detect after a rewrite is committed.
  # @spec INTENT-CONFORMANCE-ROLLOUT-002
  module ShadowEvaluationLedgerGitEvidence
    module_function

    def verify!(entries:, manifest_path:, ledger_path:, manifest_commit:)
      return if entries.empty?

      repo_root = repo_root_for(ledger_path)
      verify_manifest_commit!(repo_root, manifest_path, manifest_commit, entries.first.fetch("manifest_digest"))
      verify_ledger_commits!(repo_root, ledger_path, manifest_commit, entries.length)
    end

    def repo_root_for(path)
      stdout, stderr, status = Open3.capture3("git", "-C", File.dirname(path), "rev-parse", "--show-toplevel")
      raise invalid_ledger, "ledger evidence requires a git repository: #{stderr.strip}" unless status.success?

      stdout.strip
    end

    def verify_manifest_commit!(repo_root, manifest_path, manifest_commit, expected_digest)
      raise invalid_ledger, "manifest_commit is not a commit reachable in this repository" unless commit_exists?(repo_root, manifest_commit)

      content, _stderr, status = Open3.capture3("git", "-C", repo_root, "show", "#{manifest_commit}:#{relative_to(repo_root, manifest_path)}")
      return if status.success? && Digest::SHA256.hexdigest(content) == expected_digest

      raise invalid_ledger, "manifest_commit does not contain the frozen corpus manifest content recorded by the ledger"
    end

    def verify_ledger_commits!(repo_root, ledger_path, manifest_commit, event_count)
      relative_path = relative_to(repo_root, ledger_path)
      ensure_ledger_matches_head!(repo_root, ledger_path, relative_path)
      commits = event_commits(repo_root, relative_path, manifest_commit)

      commits.each do |sha|
        raise invalid_ledger, "ledger event commit #{sha} does not descend from the frozen manifest commit" unless strict_descendant?(repo_root, manifest_commit, sha)

        ensure_event_is_append!(repo_root, relative_path, sha)
      end

      return if commits.length == event_count

      raise invalid_ledger, "each ledger event must be introduced by a separate git commit"
    end

    def ensure_ledger_matches_head!(repo_root, ledger_path, relative_path)
      content, _stderr, status = Open3.capture3("git", "-C", repo_root, "show", "HEAD:#{relative_path}")
      # Compare bytes rather than characters so a different default external
      # encoding (US-ASCII vs UTF-8) does not turn a byte-identical working
      # tree into a validation failure.
      disk_content = File.binread(ledger_path).force_encoding(Encoding::BINARY)
      head_content = content.to_s.force_encoding(Encoding::BINARY)
      raise invalid_ledger, "ledger file must be committed before validation" unless status.success? && disk_content == head_content
    rescue Errno::ENOENT
      raise invalid_ledger, "ledger file must be committed before validation"
    end

    def event_commits(repo_root, relative_path, manifest_commit)
      stdout, _stderr, status = Open3.capture3("git", "-C", repo_root, "rev-list", "--full-history", "--reverse", "#{manifest_commit}..HEAD", "--", relative_path)
      return [] unless status.success?

      stdout.lines(chomp: true).reject(&:empty?)
    end

    def ensure_event_is_append!(repo_root, relative_path, sha)
      parent = parent_for(repo_root, sha)
      parent_content = file_content_at(repo_root, parent, relative_path)
      content = file_content_at(repo_root, sha, relative_path)
      appended_content = content.delete_prefix(parent_content)

      return if content.start_with?(parent_content) && appended_content.lines.one? && !appended_content.strip.empty?

      raise invalid_ledger, "each ledger event must be introduced by a separate git commit and must append exactly one event without changing prior events"
    end

    def parent_for(repo_root, sha)
      stdout, _stderr, status = Open3.capture3("git", "-C", repo_root, "rev-list", "--parents", "-n", "1", sha)
      parents = stdout.split.drop(1)
      return parents.first if status.success? && parents.one?

      raise invalid_ledger, "ledger event commit #{sha} must have exactly one parent"
    end

    def file_content_at(repo_root, commit, relative_path)
      content, _stderr, status = Open3.capture3("git", "-C", repo_root, "show", "#{commit}:#{relative_path}")
      return content if status.success?

      ""
    end

    def commit_exists?(repo_root, sha)
      _stdout, _stderr, status = Open3.capture3("git", "-C", repo_root, "cat-file", "-e", "#{sha}^{commit}")
      status.success?
    end

    def strict_descendant?(repo_root, ancestor, descendant)
      return false if ancestor == descendant

      _stdout, _stderr, status = Open3.capture3("git", "-C", repo_root, "merge-base", "--is-ancestor", ancestor, descendant)
      status.success?
    end

    def relative_to(repo_root, path)
      relative_path = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(repo_root)).to_s
      raise invalid_ledger, "ledger evidence paths must be inside the git repository" if relative_path == ".." || relative_path.start_with?("../")

      relative_path
    end

    def invalid_ledger
      IntentConformance::ShadowEvaluationLedger::InvalidLedger
    end
  end
end
