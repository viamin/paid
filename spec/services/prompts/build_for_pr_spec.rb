# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Prompts::BuildForPr do
  let(:project) { create(:project, allowed_github_usernames: [ "trusteduser" ]) }
  let(:github_client) { instance_double(GithubClient) }

  let(:pr_data) do
    OpenStruct.new(
      title: "Fix authentication flow",
      body: "This PR fixes the auth redirect bug.",
      head: OpenStruct.new(ref: "fix-auth", sha: "abc123"),
      base: OpenStruct.new(ref: "main")
    )
  end

  before do
    allow(github_client).to receive(:pull_request)
      .with(project.full_name, 42)
      .and_return(pr_data)



    allow(github_client).to receive_messages(check_runs_for_ref: [], review_threads: [], issue_comments: [])
  end

  describe ".call" do
    subject(:prompt) do
      described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )
    end

    it "includes the PR title and number" do
      expect(prompt).to include("Fix authentication flow")
      expect(prompt).to include("#42")
    end

    it "includes the PR body" do
      expect(prompt).to include("This PR fixes the auth redirect bug.")
    end

    it "includes the base branch" do
      expect(prompt).to include("`main`")
    end

    it "includes instructions" do
      expect(prompt).to include("Set up the project first")
      expect(prompt).to include("commit all your changes")
      expect(prompt).to include("Do not push")
    end

    it "includes rules" do
      expect(prompt).to include("MUST pass before every commit")
      expect(prompt).to include("Never use `--no-verify`")
      expect(prompt).to include("Fix forward")
    end

    it "includes language-specific lint command for ruby" do
      expect(prompt).to include("bundle exec rubocop")
    end

    it "includes language-specific test command for ruby" do
      expect(prompt).to include("bundle exec rspec")
    end

    it "omits merge conflicts section when rebase succeeded" do
      expect(prompt).not_to include("Merge Conflicts")
    end

    it "omits CI failures section when no checks are failing" do
      expect(prompt).not_to include("CI Failures")
    end

    it "omits code review section when no unresolved threads" do
      expect(prompt).not_to include("Code Review Comments")
    end

    it "omits conversation section when no trusted comments" do
      expect(prompt).not_to include("Conversation Comments")
    end

    it "omits issue requirements section when no issue" do
      expect(prompt).not_to include("Issue Requirements")
    end
  end

  describe "merge conflicts section" do
    it "includes merge conflicts instructions when rebase failed" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: false
      )

      expect(prompt).to include("Merge Conflicts")
      expect(prompt).to include("git merge origin/main")
      expect(prompt).to include("resolve all conflicts")
    end
  end

  describe "CI failures section" do
    before do
      allow(github_client).to receive(:check_runs_for_ref)
        .with(project.full_name, "abc123")
        .and_return([
          { name: "rspec", conclusion: "failure" },
          { name: "rubocop", conclusion: "success" },
          { name: "build", conclusion: "cancelled" }
        ])
    end

    it "includes failing check names" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("CI Failures")
      expect(prompt).to include("rspec (failure)")
      expect(prompt).to include("build (cancelled)")
      expect(prompt).not_to include("rubocop (success)")
    end
  end

  describe "code review section" do
    before do
      allow(github_client).to receive(:review_threads)
        .with(project.full_name, 42)
        .and_return([
          {
            id: "thread_1",
            is_resolved: false,
            comments: [
              { body: "This method is too long", path: "app/models/user.rb", line: 42, author: "reviewer" }
            ]
          },
          {
            id: "thread_2",
            is_resolved: true,
            comments: [
              { body: "Already fixed", path: "app/models/post.rb", line: 10, author: "reviewer" }
            ]
          }
        ])
    end

    it "includes unresolved review threads" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("Code Review Comments")
      expect(prompt).to include("This method is too long")
      expect(prompt).to include("app/models/user.rb:42")
    end

    it "excludes resolved threads" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).not_to include("Already fixed")
    end
  end

  describe "conversation comments section" do
    before do
      allow(github_client).to receive(:issue_comments)
        .with(project.full_name, 42)
        .and_return([
          OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "Please also fix the tests"),
          OpenStruct.new(user: OpenStruct.new(login: "randomuser"), body: "Ignore this")
        ])
    end

    it "includes comments from trusted users only" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("Conversation Comments")
      expect(prompt).to include("Please also fix the tests")
      expect(prompt).not_to include("Ignore this")
    end
  end

  describe "issue requirements section" do
    let(:issue) do
      create(:issue,
        project: project,
        title: "Add dark mode",
        github_number: 99,
        body: "Implement dark mode toggle in settings.")
    end

    it "includes issue requirements when issue is provided" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true,
        issue: issue
      )

      expect(prompt).to include("Issue Requirements")
      expect(prompt).to include("Add dark mode")
      expect(prompt).to include("#99")
      expect(prompt).to include("Implement dark mode toggle in settings.")
      expect(prompt).to include("Evaluate whether the current PR changes fully implement")
    end
  end

  describe "language detection" do
    let(:python_project) do
      proj = create(:project, allowed_github_usernames: [ "trusteduser" ])
      proj.define_singleton_method(:detected_language) { "python" }
      proj
    end

    before do
      allow(github_client).to receive(:pull_request)
        .with(python_project.full_name, 42)
        .and_return(pr_data)
    end

    it "uses detected language for lint and test commands" do
      prompt = described_class.call(
        project: python_project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("ruff check .")
      expect(prompt).to include("pytest")
    end
  end

  describe "priority ordering" do
    it "orders priorities correctly with all sections present" do
      allow(github_client).to receive_messages(check_runs_for_ref: [ { name: "ci", conclusion: "failure" } ], review_threads: [ { id: "t1", is_resolved: false, comments: [ { body: "fix", path: "a.rb", line: 1, author: "r" } ] } ], issue_comments: [ OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "comment") ])

      issue = create(:issue, project: project, title: "Issue", github_number: 1, body: "body")

      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: false,
        issue: issue
      )

      conflicts_pos = prompt.index("Resolve merge conflicts")
      ci_pos = prompt.index("Fix CI failures")
      issue_pos = prompt.index("Close implementation gaps")
      review_pos = prompt.index("Address code review comments")
      comments_pos = prompt.index("Address conversation comments")

      expect(conflicts_pos).to be < ci_pos
      expect(ci_pos).to be < issue_pos
      expect(issue_pos).to be < review_pos
      expect(review_pos).to be < comments_pos
    end
  end

  describe "error resilience" do
    it "omits CI section when check_runs_for_ref raises" do
      allow(github_client).to receive(:check_runs_for_ref)
        .and_raise(GithubClient::ApiError.new("API error"))

      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).not_to include("CI Failures")
    end

    it "omits review section when review_threads raises" do
      allow(github_client).to receive(:review_threads)
        .and_raise(GithubClient::ApiError.new("API error"))

      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).not_to include("Code Review Comments")
    end

    it "omits conversation section when issue_comments raises" do
      allow(github_client).to receive(:issue_comments)
        .and_raise(GithubClient::ApiError.new("API error"))

      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).not_to include("Conversation Comments")
    end
  end
end
