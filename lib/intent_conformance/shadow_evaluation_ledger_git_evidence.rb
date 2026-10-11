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
  # manifest_commit really contain the frozen manifest, and did an immutable,
  # separate descendant commit introduce each ledger event? The latter binds
  # every current JSONL line to the commit Git says introduced it, instead of
  # merely counting unrelated commits that happened to touch the ledger.
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
      commits = event_commits(repo_root, relative_path)
      raise invalid_ledger, "ledger file has no committed events to verify" unless commits.length == event_count
      raise invalid_ledger, "each ledger event must be introduced by a separate git commit" unless commits.uniq.length == event_count

      commits.each do |sha|
        next if strict_descendant?(repo_root, manifest_commit, sha)

        raise invalid_ledger, "ledger event commit #{sha} does not descend from the frozen manifest commit"
      end
    end

    def ensure_ledger_matches_head!(repo_root, ledger_path, relative_path)
      content, _stderr, status = Open3.capture3("git", "-C", repo_root, "show", "HEAD:#{relative_path}")
      raise invalid_ledger, "ledger file must be committed before validation" unless status.success? && File.binread(ledger_path) == content
    rescue Errno::ENOENT
      raise invalid_ledger, "ledger file must be committed before validation"
    end

    def event_commits(repo_root, relative_path)
      stdout, _stderr, status = Open3.capture3("git", "-C", repo_root, "blame", "--line-porcelain", "HEAD", "--", relative_path)
      return [] unless status.success?

      commits_for_nonempty_lines(stdout)
    end

    def commits_for_nonempty_lines(blame)
      commit = nil
      blame.each_line.filter_map do |line|
        match = line.match(/\A([0-9a-f]{40}) \d+ \d+/)
        commit = match[1] if match
        commit if line.start_with?("\t") && !line.strip.empty?
      end
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
