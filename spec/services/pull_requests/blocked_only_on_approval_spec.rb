# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe PullRequests::BlockedOnlyOnApproval do
  let(:project) do
    create(:project,
      owner_reviewer_login: "viamin",
      auto_merge_mode: "all",
      pr_approval_escalation_hours: 24)
  end
  let(:client) { instance_double(GithubClient) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
  let(:issue) do
    create(:issue, :pull_request,
      project: project,
      pr_review_phase: "ready",
      github_state: "open",
      labels: [ "paid-automation" ])
  end

  before do
    allow(GithubClient).to receive(:new).and_return(client)
  end

  def green_pr_data(sha: "abc123", mergeable: true, draft: false, state: "open", login: "someone-else", labels: [],
    base_branch: "main")
    OpenStruct.new(
      head: OpenStruct.new(sha: sha, repo: OpenStruct.new(fork: false)),
      base: OpenStruct.new(ref: base_branch),
      mergeable: mergeable,
      draft: draft,
      number: issue.github_number,
      state: state,
      user: OpenStruct.new(login: login),
      labels: labels.map { |name| OpenStruct.new(name: name) }
    )
  end

  def green_checks
    [ { name: "ci", conclusion: "success" } ]
  end

  def green_reviews
    [ { id: 100, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
        body: "Copilot reviewed 5 out of 5 changed files and generated no comments.",
        submitted_at: 1.hour.ago } ]
  end

  def stub_head_commit(sha:, date: 2.hours.ago)
    allow(client).to receive(:commit)
      .with(project.full_name, sha)
      .and_return(OpenStruct.new(
        commit: OpenStruct.new(committer: OpenStruct.new(date: date))
      ))
  end

  def stub_pr_data(pr_data)
    allow(client).to receive(:pull_request)
      .with(project.full_name, issue.github_number)
      .and_return(pr_data)
  end

  def stub_checks(sha, checks)
    allow(client).to receive(:check_runs_for_ref)
      .with(project.full_name, sha)
      .and_return(checks)
  end

  def stub_reviews(reviews)
    allow(client).to receive(:pull_request_reviews)
      .with(project.full_name, issue.github_number)
      .and_return(reviews)
  end

  def stub_review_threads(threads)
    allow(client).to receive(:review_threads)
      .with(project.full_name, issue.github_number)
      .and_return(threads)
  end

  # Mirrors ScanPaidPrsActivity's stub_clean_base_merge: stubs the commit
  # graph so only_base_merge_commits_since? classifies the range between
  # approval_sha and head_sha as a single clean merge of base_branch.
  def stub_clean_base_merge(approval_sha:, head_sha:, base_tip_sha:, base_branch: "main")
    merge_tree_sha = "merge_tree_sha"
    merge_commit = OpenStruct.new(
      commit: OpenStruct.new(
        tree: OpenStruct.new(sha: merge_tree_sha),
        committer: OpenStruct.new(date: 1.hour.ago)
      ),
      parents: [ OpenStruct.new(sha: approval_sha), OpenStruct.new(sha: base_tip_sha) ]
    )
    first_parent_commit = OpenStruct.new(commit: OpenStruct.new(tree: OpenStruct.new(sha: merge_tree_sha)))

    allow(client).to receive(:compare)
      .with(project.full_name, approval_sha, head_sha)
      .and_return(OpenStruct.new(status: "ahead"))
    allow(client).to receive(:commit).with(project.full_name, head_sha).and_return(merge_commit)
    allow(client).to receive(:commit).with(project.full_name, approval_sha).and_return(first_parent_commit)
    allow(client).to receive(:ref)
      .with(project.full_name, "heads/#{base_branch}")
      .and_return(OpenStruct.new(object: OpenStruct.new(sha: base_tip_sha)))
  end

  def stub_issue_comments(comments = [])
    comments.define_singleton_method(:multi_page?) { false }

    allow(client).to receive(:recent_issue_comments)
      .with(project.full_name, issue.github_number)
      .and_return(comments)
    allow(client).to receive(:issue_comments)
      .with(project.full_name, issue.github_number)
      .and_return(comments)
  end

  describe ".call" do
    it "returns true when every precondition is green and the PR is unapproved" do
      sha = "abc123"
      pr_data = green_pr_data(sha: sha)
      stub_pr_data(pr_data)
      stub_checks(sha, green_checks)
      stub_reviews(green_reviews)
      stub_review_threads([])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
    end

    it "returns false when the PR has been closed since the scan" do
      issue.update!(github_state: "closed")

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when the PR is no longer in the ready phase" do
      issue.update!(pr_review_phase: "draft")

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when the paid-skip-auto-merge label appeared since the scan" do
      issue.update!(labels: [ "paid-automation", Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL ])

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    # @spec PR-ESCALATION-025
    it "returns false when the paid-skip-auto-merge label was added on GitHub but not yet synced locally" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha, labels: [ Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL ]))

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when the PR lost mergeability since the scan (race-window merge conflicts)" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha, mergeable: false))
      stub_checks(sha, green_checks)
      stub_reviews(green_reviews)
      stub_review_threads([])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when auto-merge was disabled since the scan" do
      project.update!(auto_merge_mode: "off")

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    # @spec PR-ESCALATION-025
    it "returns false when the PR was converted to draft since the scan" do
      stub_pr_data(green_pr_data(draft: true))

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    # @spec PR-ESCALATION-025
    it "returns false when the PR was closed on GitHub since the scan" do
      stub_pr_data(green_pr_data(state: "closed"))

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when CI started failing since the scan" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, [ { name: "ci", conclusion: "failure" } ])
      stub_reviews(green_reviews)
      stub_review_threads([])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when the owner approved since the scan" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews(
        green_reviews + [
          { id: 1, user_login: "viamin", state: "APPROVED", body: "", submitted_at: Time.current }
        ]
      )
      stub_review_threads([])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when new review feedback (changes_requested) appears since the scan" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews(
        green_reviews + [
          { id: 1, user_login: "viamin", state: "CHANGES_REQUESTED",
            body: "Please fix", submitted_at: Time.current }
        ]
      )
      stub_review_threads([])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when an unresolved review thread appears since the scan" do
      sha = "abc123"
      thread = OpenStruct.new(
        id: "thread-1",
        is_resolved: false,
        comments: [
          OpenStruct.new(author: "viamin", body: "?", path: "x", line: 1,
            created_at: Time.current, commit_id: sha)
        ]
      )
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews(green_reviews)
      stub_review_threads([ thread ])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns true when the owner's APPROVED review is followed by a later COMMENTED review (latest-wins)" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews(
        green_reviews + [
          { id: 1, user_login: "viamin", state: "APPROVED", body: "LGTM", submitted_at: 2.hours.ago },
          { id: 2, user_login: "viamin", state: "COMMENTED", body: "actually, one nit", submitted_at: 1.hour.ago }
        ]
      )
      stub_review_threads([])
      stub_head_commit(sha: sha, date: 3.hours.ago)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
    end

    it "returns true when an unresolved thread's only comment is from an untrusted drive-by user" do
      sha = "abc123"
      thread = OpenStruct.new(
        id: "thread-1",
        is_resolved: false,
        comments: [
          OpenStruct.new(author: "random-passerby", body: "?", path: "x", line: 1,
            created_at: Time.current, commit_id: sha)
        ]
      )
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews(green_reviews)
      stub_review_threads([ thread ])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
    end

    it "returns true when CHANGES_REQUESTED predates the last completed run (already addressed)" do
      sha = "abc123"
      run = create(:agent_run,
        project: project,
        issue: issue,
        goal: "create_pr",
        status: "completed",
        completed_at: 1.hour.ago)
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews(
        green_reviews + [
          { id: 1, user_login: "viamin", state: "CHANGES_REQUESTED", body: "Please fix", submitted_at: 2.hours.ago }
        ]
      )
      stub_review_threads([])
      stub_head_commit(sha: sha, date: 3.hours.ago)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
      expect(run).to be_persisted
    end

    # @spec PR-ESCALATION-025
    it "returns false when a fresh trusted conversation comment appears since the last completed run" do
      sha = "abc123"
      create(:agent_run,
        project: project,
        issue: issue,
        goal: "create_pr",
        status: "completed",
        completed_at: 1.hour.ago)
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews(green_reviews)
      stub_review_threads([])
      stub_head_commit(sha: sha, date: 3.hours.ago)
      stub_issue_comments([
        OpenStruct.new(
          user: OpenStruct.new(login: "viamin"),
          body: "Please update the changelog section before merge.",
          created_at: 30.minutes.ago
        )
      ])

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when the GitHub API fails to fetch PR data (safe default)" do
      allow(client).to receive(:pull_request).and_raise(GithubClient::Error, "transient")

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when the GitHub API fails to fetch checks" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha))
      allow(client).to receive(:check_runs_for_ref).and_raise(GithubClient::Error, "transient")

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns false when the GitHub API fails to fetch reviews" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      allow(client).to receive(:pull_request_reviews).and_raise(GithubClient::Error, "transient")

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    # @spec PR-ESCALATION-025
    it "returns false when the GitHub API fails to fetch recent issue comments (safe default)" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews(green_reviews)
      stub_review_threads([])
      stub_head_commit(sha: sha)
      stub_issue_comments
      allow(client).to receive(:recent_issue_comments).and_raise(GithubClient::Error, "transient")

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    it "returns true when the PR author is the project's own agent bot (self-authored bypass)" do
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha, login: "paid-agents[bot]"))
      stub_checks(sha, green_checks)
      stub_reviews([])
      stub_review_threads([])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
    end

    it "returns false when the project has no owner_reviewer_login" do
      project.update!(owner_reviewer_login: nil)

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
    end

    context "with a manual review gate configured" do
      before do
        project.update!(
          allowed_github_usernames: [ "viamin", "alice" ],
          review_settings: {
            "enabled" => true,
            "methods" => { "manual" => { "enabled" => true, "reviewer_login" => "alice" } }
          }
        )
      end

      # @spec PR-ESCALATION-025
      it "returns true when the reviewer approved after the last push (gate complete, approval fresh)" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(
          green_reviews + [
            { id: 2, user_login: "alice", state: "APPROVED", body: "LGTM", submitted_at: 1.hour.ago }
          ]
        )
        stub_review_threads([])
        stub_head_commit(sha: sha, date: 2.hours.ago)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
      end

      # @spec PR-ESCALATION-025
      it "returns false when the configured reviewer has not approved yet (gate incomplete)" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(green_reviews)
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end

      # @spec PR-ESCALATION-025
      it "returns false when a blocking approval predates the head commit (stale review)" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(
          green_reviews + [
            { id: 2, user_login: "alice", state: "APPROVED", body: "LGTM", submitted_at: 3.hours.ago }
          ]
        )
        stub_review_threads([])
        stub_head_commit(sha: sha, date: 1.hour.ago)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end

      # @spec PR-ESCALATION-025
      # @spec AUTO-MERGE-006
      it "treats a timestamp-stale approval as fresh when only a clean base-branch merge landed since" do
        approval_sha = "approved_sha"
        head_sha = "merge_sha"

        stub_pr_data(green_pr_data(sha: head_sha, base_branch: "main"))
        stub_checks(head_sha, green_checks)
        stub_reviews(
          green_reviews + [
            { id: 2, user_login: "alice", state: "APPROVED", body: "LGTM",
              submitted_at: 3.hours.ago, commit_id: approval_sha }
          ]
        )
        stub_review_threads([])
        stub_issue_comments
        stub_clean_base_merge(approval_sha: approval_sha, head_sha: head_sha, base_tip_sha: "base_tip_sha")

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
      end

      # @spec PR-ESCALATION-025
      it "treats the configured manual reviewer's stale approval as blocking even when they are not allowlisted" do
        project.update!(allowed_github_usernames: [ "viamin" ])
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(
          green_reviews + [
            { id: 2, user_login: "alice", state: "APPROVED", body: "LGTM", submitted_at: 3.hours.ago }
          ]
        )
        stub_review_threads([])
        stub_head_commit(sha: sha, date: 1.hour.ago)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end

      # @spec PR-ESCALATION-025
      it "returns false when the reviewer's APPROVED review is followed by a later COMMENTED review" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(
          green_reviews + [
            { id: 2, user_login: "alice", state: "APPROVED", body: "LGTM", submitted_at: 2.hours.ago },
            { id: 3, user_login: "alice", state: "COMMENTED", body: "One follow-up note", submitted_at: 1.hour.ago }
          ]
        )
        stub_review_threads([])
        stub_head_commit(sha: sha, date: 3.hours.ago)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end
    end

    context "with a ci_action review gate configured" do
      before do
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => { "ci_action" => { "enabled" => true, "action_name" => "e2e-signoff" } }
        })
      end

      # @spec PR-ESCALATION-025
      it "returns true when the named check run has succeeded" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks + [ { name: "e2e-signoff", conclusion: "success" } ])
        stub_reviews(green_reviews)
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
      end

      # @spec PR-ESCALATION-025
      it "returns false when the named check run has not succeeded" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks + [ { name: "e2e-signoff", conclusion: "failure" } ])
        stub_reviews(green_reviews)
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end
    end

    context "with a copilot review-bot method configured" do
      before do
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => { "copilot" => { "enabled" => true } }
        })
      end

      # @spec PR-ESCALATION-025
      it "returns true when the latest copilot review is clean" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(green_reviews)
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
      end

      # @spec PR-ESCALATION-025
      it "returns false when a fresh non-clean copilot review body appears since the scan " \
         "(no threads, body-only feedback)" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(
          [ { id: 200, user_login: "copilot-pull-request-reviewer[bot]", state: "COMMENTED",
              body: "Found 2 issues that should be addressed.", submitted_at: 1.hour.ago } ]
        )
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end
    end

    context "with a body-only review-bot method configured" do
      before do
        project.update!(review_settings: {
          "enabled" => true,
          "methods" => { "codex" => { "enabled" => true } }
        })
      end

      # @spec PR-ESCALATION-025
      it "returns true when a clean body-only bot issue comment supersedes an older non-clean review" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(
          [ { id: 200, user_login: "chatgpt-codex-connector", state: "COMMENTED",
              body: "Found 2 issues that should be addressed.", submitted_at: 2.hours.ago } ]
        )
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments([
          OpenStruct.new(
            user: OpenStruct.new(login: "chatgpt-codex-connector"),
            body: "Codex Review: Didn't find any major issues. Bravo.",
            created_at: 1.hour.ago
          )
        ])

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
      end
    end

    context "with address_all_bot_reviews enabled and a non-configured bot review" do
      before do
        project.update!(review_settings: {
          "enabled" => true,
          "address_all_bot_reviews" => true,
          "methods" => { "copilot" => { "enabled" => true } }
        })
      end

      # @spec PR-ESCALATION-025
      it "returns false when a non-configured bot has a non-clean review" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(
          green_reviews + [
            { id: 200, user_login: "chatgpt-codex-connector", state: "COMMENTED",
              body: "Here are some suggestions.", submitted_at: 30.minutes.ago }
          ]
        )
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end

      # @spec PR-ESCALATION-025
      it "returns false when a non-configured bot left an unresolved thread" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(green_reviews)
        stub_review_threads([
          { id: 1, is_resolved: false,
            comments: [ { author: "chatgpt-codex-connector", body: "Fix this", path: "a.rb", line: 1 } ] }
        ])
        stub_head_commit(sha: sha)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end

      # @spec PR-ESCALATION-025
      it "returns true when the non-configured bot's review is clean" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(
          green_reviews + [
            { id: 200, user_login: "chatgpt-codex-connector", state: "COMMENTED",
              body: "Codex reviewed 3 files and generated no comments.", submitted_at: 30.minutes.ago }
          ]
        )
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
      end
    end

    context "when the issue declares a same-repo dependency" do
      before do
        issue.update!(body: "Depends on #4141")
      end

      # @spec PR-ESCALATION-025
      it "returns false while the dependency pull request is unmerged" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(green_reviews)
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments
        allow(client).to receive(:pull_request)
          .with(project.full_name, 4141)
          .and_return(OpenStruct.new(merged: false, merged_at: nil, state: "open"))

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(false)
      end

      # @spec PR-ESCALATION-025
      it "returns true once the dependency pull request has merged" do
        sha = "abc123"
        stub_pr_data(green_pr_data(sha: sha))
        stub_checks(sha, green_checks)
        stub_reviews(green_reviews)
        stub_review_threads([])
        stub_head_commit(sha: sha)
        stub_issue_comments
        allow(client).to receive(:pull_request)
          .with(project.full_name, 4141)
          .and_return(OpenStruct.new(merged: true, merged_at: 1.hour.ago, state: "closed"))

        expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
      end
    end
  end
end
