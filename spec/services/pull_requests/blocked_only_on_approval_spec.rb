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

  def green_pr_data(sha: "abc123", mergeable: true, login: "someone-else")
    OpenStruct.new(
      head: OpenStruct.new(sha: sha, repo: OpenStruct.new(fork: false)),
      mergeable: mergeable,
      draft: false,
      number: issue.github_number,
      user: OpenStruct.new(login: login)
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

  def stub_issue_comments(comments = [])
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

    it "returns true when the project has no owner_reviewer_login (the scan does too)" do
      project.update!(owner_reviewer_login: nil)
      sha = "abc123"
      stub_pr_data(green_pr_data(sha: sha))
      stub_checks(sha, green_checks)
      stub_reviews([])
      stub_review_threads([])
      stub_head_commit(sha: sha)
      stub_issue_comments

      expect(described_class.call(project: project, client: client, issue: issue, logger: logger)).to be(true)
    end
  end
end
