# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Automation::Signals::PullRequestCollector do
  let(:project) { instance_double(Project, id: 7, full_name: "acme/widgets") }
  let(:repository_provider) { instance_double(Automation::Providers::Github::RepositoryProvider) }
  let(:review_provider) { instance_double(Automation::Providers::Github::ReviewProvider) }
  let(:work_item_provider) { instance_double(Automation::Providers::Github::WorkItemProvider) }
  let(:providers) do
    Automation::Signals::ProviderContext.new(
      project: project,
      repository_provider: repository_provider,
      review_provider: review_provider,
      work_item_provider: work_item_provider
    )
  end
  let(:client) { instance_double(GithubClient) }
  let(:logger) { instance_double(ActiveSupport::Logger, warn: nil, info: nil) }
  let(:collector) { described_class.new(providers: providers, client: client, logger: logger) }
  let(:issue) { instance_double(Issue, github_number: 42) }

  describe "#fetch_pull_request" do
    it "normalizes the provider snapshot and preserves the fork bit needed by ci_action gating" do
      allow(repository_provider).to receive(:fetch_pull_request)
        .with(repo: "acme/widgets", number: 42)
        .and_return(build_provider_pr(head_repo_fork: true))

      # The fork bit is sourced from the provider snapshot, so the
      # collector no longer makes a second pull_request call.
      expect(client).not_to receive(:pull_request)

      snapshot = collector.fetch_pull_request(issue:)

      expect(snapshot.head.sha).to eq("abc123")
      expect(snapshot.user.login).to eq("dependabot[bot]")
      expect(snapshot[:mergeable]).to be(true)
      expect(snapshot.head.repo.fork).to be(true)
    end
  end

  describe "#fetch_reviews" do
    it "maps provider reviews into the legacy hash shape the scanner already consumes" do
      allow(review_provider).to receive(:fetch_reviews)
        .with(repo: "acme/widgets", pr_number: 42)
        .and_return([ build_provider_review ])

      reviews = collector.fetch_reviews(issue:)

      expect(reviews).to contain_exactly(
        include(
          id: 99,
          user_login: "reviewer",
          state: "CHANGES_REQUESTED",
          body: "Please fix this",
          commit_id: "def456"
        )
      )
    end
  end

  describe "#fetch_issue_comments" do
    it "returns provider-normalized issue comments for scanner conversation signals" do
      comment = Automation::Providers::Data::Comment.new(
        id: 5,
        author_login: "reviewer",
        body: "Looks good",
        created_at: Time.current,
        updated_at: nil,
        url: "https://example.test/comment/5"
      )
      allow(work_item_provider).to receive(:fetch_issue_comments)
        .with(repo: "acme/widgets", number: 42)
        .and_return([ comment ])

      expect(collector.fetch_issue_comments(issue:)).to eq([ comment ])
    end
  end

  describe "#fetch_check_runs" do
    let(:pr_snapshot) do
      Automation::Signals::PullRequestSnapshot.from_provider(build_provider_pr)
    end

    it "returns the raw check-run hashes preserving output_text and raw status for transient-failure detection" do
      checks = [
        { id: 1, name: "rspec", status: "completed", conclusion: "failure",
          details_url: "https://example.test/runs/1", job_id: "j1",
          output_text: "Error: getaddrinfo ENOTFOUND registry.npmjs.org" }
      ]
      allow(client).to receive(:check_runs_for_ref)
        .with("acme/widgets", "abc123")
        .and_return(checks)

      # Regression: the check-run signal stays client-backed so the
      # client-computed output_text (and raw status/conclusion strings)
      # the transient-failure detector relies on are not dropped.
      expect(repository_provider).not_to receive(:fetch_check_runs)

      result = collector.fetch_check_runs(pr_data: pr_snapshot)

      expect(result).to eq(checks)
      expect(result.first[:output_text]).to include("ENOTFOUND")
      expect(result.first[:status]).to eq("completed")
    end

    it "returns nil and logs a warning when the client raises" do
      allow(client).to receive(:check_runs_for_ref)
        .and_raise(GithubClient::Error, "boom")

      expect(collector.fetch_check_runs(pr_data: pr_snapshot)).to be_nil
      expect(logger).to have_received(:warn).with(
        hash_including(message: "pr_scanner.ci_check_failed", project_id: 7)
      )
    end

    it "re-raises authentication failures so the scan can fail loudly" do
      allow(client).to receive(:check_runs_for_ref)
        .and_raise(GithubClient::AuthenticationError, "bad credentials")

      expect {
        collector.fetch_check_runs(pr_data: pr_snapshot)
      }.to raise_error(GithubClient::AuthenticationError)
    end

    it "returns an empty array when no snapshot is supplied" do
      expect(collector.fetch_check_runs(pr_data: nil)).to eq([])
    end
  end

  describe "#dependency_resolved?" do
    it "is satisfied when the referenced PR is merged" do
      allow(client).to receive(:pull_request)
        .with("acme/widgets", 41)
        .and_return(OpenStruct.new(merged: true, merged_at: Time.current))

      expect(collector.dependency_resolved?(number: 41)).to be(true)
    end

    it "falls back to the issue state when the number is not a PR" do
      allow(client).to receive(:pull_request)
        .with("acme/widgets", 41)
        .and_raise(GithubClient::NotFoundError)
      allow(client).to receive(:issue)
        .with("acme/widgets", 41)
        .and_return(OpenStruct.new(state: "closed"))

      expect(collector.dependency_resolved?(number: 41)).to be(true)
    end

    it "is unsatisfied when neither a merged PR nor a closed issue exists" do
      allow(client).to receive(:pull_request)
        .with("acme/widgets", 41)
        .and_raise(GithubClient::NotFoundError)
      allow(client).to receive(:issue)
        .with("acme/widgets", 41)
        .and_return(OpenStruct.new(state: "open"))

      expect(collector.dependency_resolved?(number: 41)).to be(false)
    end

    it "is unsatisfied when the referenced PR/issue does not exist" do
      allow(client).to receive(:pull_request)
        .with("acme/widgets", 41)
        .and_raise(GithubClient::NotFoundError)
      allow(client).to receive(:issue)
        .with("acme/widgets", 41)
        .and_raise(GithubClient::NotFoundError)

      expect(collector.dependency_resolved?(number: 41)).to be(false)
    end
  end

  describe "#fetch_head_commit_date" do
    let(:pr_snapshot) { Automation::Signals::PullRequestSnapshot.from_provider(build_provider_pr) }

    it "returns the HEAD commit committer timestamp" do
      committed_at = 2.hours.ago
      allow(client).to receive(:commit)
        .with("acme/widgets", "abc123")
        .and_return(OpenStruct.new(commit: OpenStruct.new(committer: OpenStruct.new(date: committed_at))))

      expect(collector.fetch_head_commit_date(issue:, pr_data: pr_snapshot)).to eq(committed_at)
    end

    it "returns nil and logs a warning when the commit lookup fails" do
      allow(client).to receive(:commit).and_raise(GithubClient::Error, "boom")

      expect(collector.fetch_head_commit_date(issue:, pr_data: pr_snapshot)).to be_nil
      expect(logger).to have_received(:warn).with(
        hash_including(message: "pr_scanner.signal_check_failed", signal: "fetch_head_commit")
      )
    end

    it "re-raises authentication failures so the scan can fail loudly" do
      allow(client).to receive(:commit)
        .and_raise(GithubClient::AuthenticationError, "bad credentials")

      expect {
        collector.fetch_head_commit_date(issue:, pr_data: pr_snapshot)
      }.to raise_error(GithubClient::AuthenticationError)
    end

    it "returns nil when the snapshot has no head sha" do
      expect(collector.fetch_head_commit_date(issue:, pr_data: nil)).to be_nil
    end
  end

  describe "#review_diff_touches_reviewed_files?" do
    let(:review) { { id: 99, commit_id: "base123" } }

    it "returns true when the review touched files changed since the reviewed commit" do
      allow(client).to receive(:pull_request_review_comments)
        .with("acme/widgets", 42)
        .and_return([ { pull_request_review_id: 99, path: "app/models/user.rb" } ])
      allow(repository_provider).to receive(:fetch_pull_request)
        .with(repo: "acme/widgets", number: 42)
        .and_return(build_provider_pr)
      allow(client).to receive(:compare_changed_files)
        .with("acme/widgets", "base123", "abc123")
        .and_return([ "app/models/user.rb" ])

      expect(collector.review_diff_touches_reviewed_files?(issue:, review:)).to be(true)
    end

    it "returns false when no reviewed file changed" do
      allow(client).to receive(:pull_request_review_comments)
        .with("acme/widgets", 42)
        .and_return([ { pull_request_review_id: 99, path: "app/models/user.rb" } ])
      allow(repository_provider).to receive(:fetch_pull_request)
        .with(repo: "acme/widgets", number: 42)
        .and_return(build_provider_pr)
      allow(client).to receive(:compare_changed_files)
        .with("acme/widgets", "base123", "abc123")
        .and_return([ "README.md" ])

      expect(collector.review_diff_touches_reviewed_files?(issue:, review:)).to be(false)
    end

    it "returns true when review comments cannot be fetched" do
      allow(client).to receive(:pull_request_review_comments)
        .with("acme/widgets", 42)
        .and_raise(GithubClient::Error, "boom")

      expect(collector.review_diff_touches_reviewed_files?(issue:, review:)).to be(true)
      expect(logger).to have_received(:warn).with(
        hash_including(message: "pr_scanner.signal_check_failed", signal: "review_comments")
      )
    end
  end

  # @spec AUTO-MERGE-005
  describe "#only_base_merge_commits_since?" do
    def approval_sha
      "approved_sha"
    end

    def head_sha
      "head_sha"
    end

    def second_parent_sha
      "second_parent_sha"
    end

    def base_tip_sha
      "base_tip_sha"
    end

    def base_ref
      OpenStruct.new(object: OpenStruct.new(sha: base_tip_sha))
    end

    # HEAD as a clean two-parent merge of base: tree matches its first
    # parent (no conflict resolution) and the first parent is the
    # approval commit, so a single FP-chain step lands on the approval.
    def merge_commit
      OpenStruct.new(
        sha: head_sha,
        commit: OpenStruct.new(tree: OpenStruct.new(sha: "merge_tree")),
        parents: [
          OpenStruct.new(sha: approval_sha),
          OpenStruct.new(sha: second_parent_sha)
        ]
      )
    end

    def first_parent_commit
      OpenStruct.new(
        commit: OpenStruct.new(tree: OpenStruct.new(sha: "merge_tree"))
      )
    end

    # Stubs the FP walk for the cleanest single-merge scenario: the
    # ancestry compare, the base tip ref, the merge + first-parent
    # commit lookups, and the second-parent reachability check.
    # Examples override whichever piece they make dirty.
    def stub_clean_first_parent_walk
      allow(client).to receive(:compare)
        .with("acme/widgets", approval_sha, head_sha)
        .and_return(OpenStruct.new(status: "ahead"))
      allow(client).to receive(:ref)
        .with("acme/widgets", "heads/main")
        .and_return(base_ref)
      allow(client).to receive(:commit)
        .with("acme/widgets", head_sha)
        .and_return(merge_commit)
      allow(client).to receive(:commit)
        .with("acme/widgets", approval_sha)
        .and_return(first_parent_commit)
      allow(client).to receive(:compare)
        .with("acme/widgets", second_parent_sha, base_tip_sha)
        .and_return(OpenStruct.new(status: "ahead"))
    end

    # Stubs an FP chain where HEAD is a single-parent author commit on
    # top of a clean base merge: head_sha → author_sha → merge_sha →
    # approval_sha. The author commit must invalidate the approval.
    def stub_mixed_first_parent_walk
      author_sha = "author_commit_sha"
      merge_sha = "merge_sha"
      author_commit = OpenStruct.new(
        sha: author_sha,
        commit: OpenStruct.new(tree: OpenStruct.new(sha: "author_tree")),
        parents: [ OpenStruct.new(sha: merge_sha) ]
      )
      merge_commit = OpenStruct.new(
        sha: merge_sha,
        commit: OpenStruct.new(tree: OpenStruct.new(sha: "merge_tree")),
        parents: [
          OpenStruct.new(sha: approval_sha),
          OpenStruct.new(sha: second_parent_sha)
        ]
      )
      head_commit = OpenStruct.new(
        sha: head_sha,
        commit: OpenStruct.new(tree: OpenStruct.new(sha: "author_tree")),
        parents: [ OpenStruct.new(sha: author_sha) ]
      )

      allow(client).to receive(:compare)
        .with("acme/widgets", approval_sha, head_sha)
        .and_return(OpenStruct.new(status: "ahead"))
      allow(client).to receive(:commit)
        .with("acme/widgets", head_sha)
        .and_return(head_commit)
      allow(client).to receive(:commit)
        .with("acme/widgets", author_sha)
        .and_return(author_commit)
      allow(client).to receive(:commit)
        .with("acme/widgets", merge_sha)
        .and_return(merge_commit)
      allow(client).to receive(:commit)
        .with("acme/widgets", approval_sha)
        .and_return(first_parent_commit)
      allow(client).to receive(:compare)
        .with("acme/widgets", second_parent_sha, base_tip_sha)
        .and_return(OpenStruct.new(status: "ahead"))
    end

    before do
      allow(client).to receive(:ref)
        .with("acme/widgets", "heads/main")
        .and_return(base_ref)
    end

    it "returns true when the post-approval range is a clean base merge" do
      stub_clean_first_parent_walk

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(true)
    end

    it "returns true when compare response also lists base-branch commits brought in by the merge" do
      # Regression for the review-thread scenario where the merge brought
      # in base-branch commits: GitHub's compare endpoint is equivalent
      # to `git log BASE..HEAD` and therefore also returns the base-
      # branch commits that arrived only through the merge's second
      # parent. The FP walk ignores those (they are content-free by
      # transitivity) and the approval stays fresh.
      stub_clean_first_parent_walk
      allow(client).to receive(:compare)
        .with("acme/widgets", approval_sha, head_sha)
        .and_return(OpenStruct.new(
          status: "ahead",
          ahead_by: 5,
          commits: [
            OpenStruct.new(sha: head_sha),
            OpenStruct.new(sha: "base_commit_4_sha"),
            OpenStruct.new(sha: "base_commit_3_sha"),
            OpenStruct.new(sha: "base_commit_2_sha"),
            OpenStruct.new(sha: "base_commit_1_sha")
          ]
        ))

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(true)
    end

    it "returns false when HEAD itself is a single-parent commit on the FP chain" do
      # HEAD is a single-parent commit (one parent, not two): that is
      # author-side feature-branch content and must invalidate the
      # approval. The merge's first-parent check is what matters —
      # whether HEAD happens to also be reachable from base tip does
      # not change that the FP chain is not content-free.
      allow(client).to receive(:compare)
        .with("acme/widgets", approval_sha, head_sha)
        .and_return(OpenStruct.new(status: "ahead"))
      allow(client).to receive(:commit)
        .with("acme/widgets", head_sha)
        .and_return(OpenStruct.new(
          sha: head_sha,
          commit: OpenStruct.new(tree: OpenStruct.new(sha: "head_tree")),
          parents: [ OpenStruct.new(sha: approval_sha) ]
        ))

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(false)
    end

    it "returns false when a merge commit resolved conflicts (tree differs from first parent)" do
      stub_clean_first_parent_walk
      allow(client).to receive(:commit)
        .with("acme/widgets", approval_sha)
        .and_return(OpenStruct.new(
          commit: OpenStruct.new(tree: OpenStruct.new(sha: "different_tree"))
        ))

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(false)
    end

    it "returns false when a merge commit merges in a branch that is not the PR base" do
      stub_clean_first_parent_walk
      allow(client).to receive(:compare)
        .with("acme/widgets", second_parent_sha, base_tip_sha)
        .and_return(OpenStruct.new(status: "diverged"))

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(false)
    end

    it "returns false when the FP chain has a clean merge followed by a single-parent author commit" do
      # HEAD is a single-parent author commit on top of a clean merge
      # that brought in base. The merge itself is content-free, but
      # the FP chain still contains author-side content (the HEAD
      # commit) and the approval must be invalidated.
      stub_mixed_first_parent_walk

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(false)
    end

    it "returns false when compare reports the history diverged (force-push dropped the approval)" do
      allow(client).to receive(:compare)
        .with("acme/widgets", approval_sha, head_sha)
        .and_return(OpenStruct.new(status: "diverged"))

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(false)
    end

    it "returns false when a commit lookup fails mid-walk (fail closed)" do
      allow(client).to receive(:compare)
        .with("acme/widgets", approval_sha, head_sha)
        .and_return(OpenStruct.new(status: "ahead"))
      allow(client).to receive(:commit)
        .with("acme/widgets", head_sha)
        .and_raise(GithubClient::Error, "boom")

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(false)
      expect(logger).to have_received(:warn).with(
        hash_including(message: "pr_scanner.signal_check_failed", signal: "clean_base_merge_range")
      )
    end

    it "returns false (fail closed) when the first-parent walk exceeds the response cap" do
      # Stub the walk limit down so the cycle exhausts it quickly. The
      # production limit (250) is documented in the spec; this test
      # only needs to exercise the truncation branch. head_sha's first
      # parent loops back to itself so the walk never finds approval_sha.
      stub_const("Automation::Signals::PullRequestCollector::FIRST_PARENT_WALK_LIMIT", 3)
      stub_clean_first_parent_walk
      allow(client).to receive(:commit)
        .with("acme/widgets", head_sha)
        .and_return(cycle_commit)

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(false)
      expect(logger).to have_received(:warn).with(hash_including(
        message: "pr_scanner.review_freshness_range_truncated",
        first_parent_steps: 3,
        walk_limit: 3
      ))
    end

    # Cycle: head_sha's first parent points back to itself so the FP
    # walk never reaches approval_sha and the step bound trips.
    def cycle_commit
      OpenStruct.new(
        sha: head_sha,
        commit: OpenStruct.new(tree: OpenStruct.new(sha: "merge_tree")),
        parents: [
          OpenStruct.new(sha: head_sha),
          OpenStruct.new(sha: second_parent_sha)
        ]
      )
    end

    it "returns false when the base branch tip cannot be resolved" do
      allow(client).to receive(:ref)
        .with("acme/widgets", "heads/main")
        .and_return(nil)

      result = collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(false)
      expect(logger).to have_received(:warn).with(
        hash_including(message: "pr_scanner.signal_check_failed", signal: "clean_base_merge_range")
      )
    end

    it "returns true when approval_sha equals head_sha (no new commits since approval)" do
      allow(client).to receive(:compare)

      result = collector.only_base_merge_commits_since?(
        approval_sha: head_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(result).to be(true)
      expect(client).not_to have_received(:compare)
    end

    it "returns false when any required input is blank" do
      cases = [
        { approval_sha: nil, head_sha: head_sha, base_branch: "main" },
        { approval_sha: approval_sha, head_sha: nil, base_branch: "main" },
        { approval_sha: approval_sha, head_sha: head_sha, base_branch: nil },
        { approval_sha: "", head_sha: "", base_branch: "main" },
        { approval_sha: approval_sha, head_sha: head_sha, base_branch: "" },
        { approval_sha: "", head_sha: "", base_branch: "" }
      ]

      cases.each do |kwargs|
        result = collector.only_base_merge_commits_since?(**kwargs, issue: issue)
        expect(result).to be(false), "expected false for #{kwargs.inspect}"
      end
    end

    it "logs the classification decision so a stall is diagnosable" do
      stub_clean_first_parent_walk

      collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(logger).to have_received(:info).with(
        hash_including(
          message: "pr_scanner.review_freshness_range_classified",
          approval_sha: approval_sha,
          head_sha: head_sha,
          first_parent_steps: 1
        )
      )
    end

    it "logs the stale classification so the failure mode is diagnosable" do
      allow(client).to receive(:compare)
        .with("acme/widgets", approval_sha, head_sha)
        .and_return(OpenStruct.new(status: "ahead"))
      allow(client).to receive(:commit)
        .with("acme/widgets", head_sha)
        .and_return(OpenStruct.new(
          sha: head_sha,
          commit: OpenStruct.new(tree: OpenStruct.new(sha: "head_tree")),
          parents: [ OpenStruct.new(sha: approval_sha) ]
        ))

      collector.only_base_merge_commits_since?(
        approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
      )

      expect(logger).to have_received(:warn).with(
        hash_including(
          message: "pr_scanner.review_freshness_range_stale",
          reason: "single_parent_commit"
        )
      )
    end

    it "re-raises authentication failures so the scan can fail loudly" do
      allow(client).to receive(:compare)
        .with("acme/widgets", approval_sha, head_sha)
        .and_raise(GithubClient::AuthenticationError, "bad credentials")

      expect {
        collector.only_base_merge_commits_since?(
          approval_sha: approval_sha, head_sha: head_sha, base_branch: "main", issue: issue
        )
      }.to raise_error(GithubClient::AuthenticationError)
    end
  end

  def build_provider_pr(head_repo_fork: nil)
    Automation::Providers::Data::PullRequest.new(
      number: 42,
      title: "Upgrade deps",
      body: "body",
      state: :open,
      draft: false,
      merged: false,
      mergeable: true,
      head_sha: "abc123",
      head_ref: "feature",
      base_ref: "main",
      author_login: "dependabot[bot]",
      labels: [ "paid" ],
      created_at: Time.current,
      updated_at: Time.current,
      merged_at: nil,
      url: "https://example.test/pr/42",
      raw_state: "open",
      head_repo_fork: head_repo_fork
    )
  end

  def build_provider_review
    Automation::Providers::Data::Review.new(
      id: 99,
      author_login: "reviewer",
      state: :changes_requested,
      raw_state: "CHANGES_REQUESTED",
      body: "Please fix this",
      submitted_at: Time.current,
      commit_sha: "def456"
    )
  end
end
