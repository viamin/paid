# frozen_string_literal: true

require "rails_helper"
require "ostruct"
require "securerandom"

RSpec.describe Prompts::BuildForPr do
  def recent_comments_with_page_state(comments, multi_page:, older_pages_available: multi_page, next_older_page_url: nil)
    next_url = older_pages_available ? (next_older_page_url || "https://api.github.com/repos/o/r/issues/42/comments?page=1") : nil
    comments.define_singleton_method(:multi_page?) { multi_page }
    comments.define_singleton_method(:older_pages_available?) { older_pages_available }
    comments.define_singleton_method(:next_older_page_url) { next_url }
    comments
  end

  def trusted_recent_comments(count)
    Array.new(count) { |index| OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "Trusted #{index + 1}") }
  end

  def untrusted_recent_comments(count)
    Array.new(count) { |index| OpenStruct.new(user: OpenStruct.new(login: "bot#{index}"), body: "Noise #{index}") }
  end

  def stub_prompt_comment_settings(project, settings)
    allow(AgentRuns::UserSettingsResolver).to receive(:call)
      .with(project: project, strict: false)
      .and_return(settings)
  end

  def build_trusted_comment(body)
    OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: body)
  end

  let(:project) { create(:project, allowed_github_usernames: [ "trusteduser" ]) }
  let(:github_client) { instance_double(GithubClient) }
  let(:user_settings) { instance_double(UserSetting, max_prompt_comments: 20, max_comment_length: 2000) }

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



    allow(github_client).to receive_messages(
      check_runs_for_ref: [],
      review_threads: [],
      recent_issue_comments: []
    )
    allow(AgentRuns::UserSettingsResolver).to receive(:call).and_return(user_settings)
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

    it "renders the instructions shell from an explicit prompt version when provided" do
      prompt = create(:prompt, :global, slug: "test.#{SecureRandom.hex(8)}")
      stale_version = prompt.create_version!(
        template: "Pinned instructions {{lint_command}}",
        variables: [
          { "name" => "lint_command", "required" => true, "description" => "Lint command" }
        ]
      )
      prompt.create_version!(
        template: "Current instructions should not render",
        variables: []
      )

      rendered = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true,
        prompt_version: stale_version
      )

      expect(rendered).to include("Pinned instructions bundle exec rubocop")
      expect(rendered).not_to include("Current instructions should not render")
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
      expect(prompt).to include("Install dependencies")
      expect(prompt).to include("commit all your changes")
      expect(prompt).to include("Do not push")
    end

    it "omits the already-addressed marker instruction when no unresolved review threads are present" do
      expect(prompt).not_to include(Prompts::BuildForPr::ALREADY_ADDRESSED_MARKER)
      expect(prompt).not_to include("do not make a no-op commit")
    end

    it "includes proactive scan step" do
      expect(prompt).to include("Proactive scan")
      expect(prompt).to include("review the **entire diff**")
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
      expect(prompt).not_to include("CI Status: FAILING")
    end

    it "omits code review section when no unresolved threads" do
      expect(prompt).not_to include("Code Review Comments")
    end

    it "omits review-specific scan instruction when no unresolved threads" do
      expect(prompt).not_to include("same classes of issues the reviewers")
    end

    it "omits conversation section when no trusted comments" do
      expect(prompt).not_to include("Conversation Comments")
    end

    it "omits issue requirements section when no issue" do
      expect(prompt).not_to include("Issue Requirements")
    end
  end

  describe "#includes_review_threads?" do
    it "returns false when there are no unresolved review threads" do
      builder = described_class.new(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(builder.includes_review_threads?).to be(false)
    end

    it "returns true when unresolved review threads are present" do
      allow(github_client).to receive(:review_threads)
        .with(project.full_name, 42)
        .and_return([
          { id: "thread_1", is_resolved: false, comments: [ { body: "Needs a fix", author: "reviewer" } ] }
        ])

      builder = described_class.new(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(builder.includes_review_threads?).to be(true)
    end
  end

  describe "#unresolved_review_thread_ids" do
    it "returns only unresolved review thread ids" do
      allow(github_client).to receive(:review_threads)
        .with(project.full_name, 42)
        .and_return([
          { id: "thread_1", is_resolved: false, comments: [ { body: "Needs a fix", author: "reviewer" } ] },
          { id: "thread_2", is_resolved: true, comments: [ { body: "Already fixed", author: "reviewer" } ] },
          { id: nil, is_resolved: false, comments: [ { body: "Missing id", author: "reviewer" } ] }
        ])

      builder = described_class.new(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(builder.unresolved_review_thread_ids).to eq([ "thread_1" ])
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
          { id: 1, name: "rspec", conclusion: "failure", output_text: "role \"root\" does not exist" },
          { id: 2, name: "rubocop", conclusion: "success", output_text: "ok" },
          { id: 3, name: "build", conclusion: "cancelled", output_text: "" }
        ])
      allow(github_client).to receive(:check_run_log)
        .with(project.full_name, { id: 1, name: "rspec", conclusion: "failure", output_text: "role \"root\" does not exist" })
        .and_return("")
      allow(github_client).to receive(:check_run_log)
        .with(project.full_name, { id: 3, name: "build", conclusion: "cancelled", output_text: "" })
        .and_return("database \"railscrawler_test\" does not exist")
    end

    it "includes failing check names" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("CI Status: FAILING")
      expect(prompt).to include("rspec (failure)")
      expect(prompt).to include("build (cancelled)")
      expect(prompt).not_to include("rubocop (success)")
    end

    it "includes pre-processed failure output" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("Error output (pre-processed)")
      expect(prompt).to include("role \"root\" does not exist")
      expect(prompt).to include("database \"railscrawler_test\" does not exist")
      expect(prompt).to include("Fix the issue causing these CI failures")
    end

    it "includes CI failure guidance" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("database error")
      expect(prompt).to include("RAILS_ENV")
    end

    it "includes failure type hints for database errors" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("Detected failure type")
    end

    it "includes workflow content when available" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "failed", details_url: "https://github.com/owner/repo/actions/runs/999/job/1" }
      allow(github_client).to receive(:check_runs_for_ref)
        .with(project.full_name, "abc123")
        .and_return([ check ])
      allow(github_client).to receive(:check_run_log).with(project.full_name, check).and_return("")
      run_response = double(path: ".github/workflows/test.yml")
      allow(github_client).to receive_messages(actions_run: run_response, file_content: "name: Test\non: push")

      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("CI Workflow Configuration")
      expect(prompt).to include(".github/workflows/test.yml")
    end
  end

  describe "pending CI checks" do
    before do
      allow(github_client).to receive(:check_runs_for_ref)
        .with(project.full_name, "abc123")
        .and_return([
          { name: "rspec", conclusion: nil }
        ])
    end

    it "does not present pending checks as failures" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).not_to include("CI Status: FAILING")
      expect(prompt).not_to include("Fix CI failures")
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

    it "includes review-specific scan instruction in the proactive scan step" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("same classes of issues the reviewers")
      expect(prompt).to include("Proactive scan")
    end

    it "includes the already-addressed marker instruction when unresolved review threads are present" do
      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include(Prompts::BuildForPr::ALREADY_ADDRESSED_MARKER)
      expect(prompt).to include("do not make a no-op commit")
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
    let(:recent_comments) do
      [
        OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "Please also fix the tests"),
        OpenStruct.new(user: OpenStruct.new(login: "randomuser"), body: "Ignore this")
      ]
    end

    before do
      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 1)
        .and_return(recent_comments)
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

    it "excludes Paid agent update comments from trusted conversation context" do
      agent_update = build_trusted_comment(
        "#{Activities::CompleteExistingPrRunActivity::COMMENT_MARKER}\n## Agent Update\n\nReverified the branch."
      )
      actionable_comment = build_trusted_comment("Please tighten the provider validation.")

      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 1)
        .and_return([ agent_update, actionable_comment ])

      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("Conversation Comments")
      expect(prompt).to include("Please tighten the provider validation.")
      expect(prompt).not_to include(Activities::CompleteExistingPrRunActivity::COMMENT_MARKER)
      expect(prompt).not_to include("Reverified the branch.")
    end

    it "excludes Paid escalation notes from trusted conversation context" do
      escalation_note = build_trusted_comment(
        "#{Activities::MarkEscalatedActivity::COMMENT_MARKER}\n**Escalation Note**\n\nManual review is required."
      )
      actionable_comment = build_trusted_comment("Please resolve the failing spec before re-requesting review.")

      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 1)
        .and_return([ escalation_note, actionable_comment ])

      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )

      expect(prompt).to include("Conversation Comments")
      expect(prompt).to include("Please resolve the failing spec before re-requesting review.")
      expect(prompt).not_to include(Activities::MarkEscalatedActivity::COMMENT_MARKER)
      expect(prompt).not_to include("**Escalation Note**")
    end

    it "keeps only the most recent trusted comments within the limit" do
      limited_settings = instance_double(UserSetting, max_prompt_comments: 2, max_comment_length: 2000)
      limited_comments = [
        OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "Oldest trusted"),
        OpenStruct.new(user: OpenStruct.new(login: "randomuser"), body: "Untrusted"),
        OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "Newer trusted"),
        OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "Newest trusted")
      ]
      allow(AgentRuns::UserSettingsResolver).to receive(:call)
        .with(project: project, strict: false)
        .and_return(limited_settings)
      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 1)
        .and_return(limited_comments)

      prompt = described_class.call(project: project, pr_number: 42, github_client: github_client, rebase_succeeded: true)

      expect(prompt).to include("Newer trusted")
      expect(prompt).to include("Newest trusted")
      expect(prompt).not_to include("Oldest trusted")
      expect(prompt).not_to include("Untrusted")
    end

    it "truncates long recent comment bodies" do
      truncating_settings = instance_double(UserSetting, max_prompt_comments: 20, max_comment_length: 20)
      long_comment = [
        OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "This comment is definitely longer than twenty characters")
      ]
      allow(AgentRuns::UserSettingsResolver).to receive(:call)
        .with(project: project, strict: false)
        .and_return(truncating_settings)
      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 1)
        .and_return(long_comment)

      prompt = described_class.call(project: project, pr_number: 42, github_client: github_client, rebase_succeeded: true)

      expect(prompt).to include("This comment is defi… [truncated]")
    end

    it "fetches enough trailing pages to honor limits above 200 comments" do
      expanded_settings = instance_double(UserSetting, max_prompt_comments: 205, max_comment_length: 2000)
      expanded_comments = Array.new(205) do |index|
        OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "Trusted comment #{index + 1}")
      end

      allow(AgentRuns::UserSettingsResolver).to receive(:call)
        .with(project: project, strict: false)
        .and_return(expanded_settings)
      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 3)
        .and_return(expanded_comments)

      prompt = described_class.call(project: project, pr_number: 42, github_client: github_client, rebase_succeeded: true)

      expect(prompt).to include("Trusted comment 1")
      expect(prompt).to include("Trusted comment 205")
    end

    it "clamps the initial trailing page window to the safety cap" do
      expanded_settings = instance_double(UserSetting, max_prompt_comments: 5_000, max_comment_length: 2000)
      expanded_comments = recent_comments_with_page_state(
        trusted_recent_comments(25),
        multi_page: true,
        older_pages_available: false
      )

      allow(AgentRuns::UserSettingsResolver).to receive(:call)
        .with(project: project, strict: false)
        .and_return(expanded_settings)
      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 10)
        .and_return(expanded_comments)

      described_class.call(project: project, pr_number: 42, github_client: github_client, rebase_succeeded: true)

      expect(github_client).to have_received(:recent_issue_comments)
        .with(project.full_name, 42, pages: 10)
        .once
    end

    context "when trusted comments are sparse and backfill is needed" do
      let(:older_page_url) { "https://api.github.com/repos/o/r/issues/42/comments?page=5" }

      before do
        limited_settings = instance_double(UserSetting, max_prompt_comments: 20, max_comment_length: 2000)
        newest = recent_comments_with_page_state(
          untrusted_recent_comments(100), multi_page: true, older_pages_available: true,
          next_older_page_url: older_page_url
        )
        older = recent_comments_with_page_state(trusted_recent_comments(20), multi_page: true, older_pages_available: true)

        stub_prompt_comment_settings(project, limited_settings)
        allow(github_client).to receive(:recent_issue_comments).with(project.full_name, 42, pages: 1).and_return(newest)
        allow(github_client).to receive(:fetch_issue_comment_page).with(older_page_url).and_return(older)
      end

      it "fetches older pages incrementally until it collects enough trusted comments" do
        prompt = described_class.call(project: project, pr_number: 42, github_client: github_client, rebase_succeeded: true)

        expect(prompt).to include("Trusted 1")
        expect(prompt).to include("Trusted 20")
        expect(prompt).not_to include("Noise 0")
        expect(github_client).to have_received(:recent_issue_comments).once
        expect(github_client).to have_received(:fetch_issue_comment_page).once
      end
    end

    it "stops backfilling once the fetched window already includes the oldest page" do
      limited_settings = instance_double(UserSetting, max_prompt_comments: 20, max_comment_length: 2000)
      all_recent_comments = recent_comments_with_page_state(
        trusted_recent_comments(5) + untrusted_recent_comments(10),
        multi_page: true,
        older_pages_available: false
      )

      stub_prompt_comment_settings(project, limited_settings)
      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 1)
        .and_return(all_recent_comments)

      prompt = described_class.call(project: project, pr_number: 42, github_client: github_client, rebase_succeeded: true)

      expect(prompt).to include("Trusted 1")
      expect(prompt).to include("Trusted 5")
      expect(github_client).to have_received(:recent_issue_comments).once
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

    it "includes issue requirements when a linked issue is provided" do
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

    it "omits issue requirements when issue is the PR itself" do
      pr_issue = create(:issue, :pull_request,
        project: project,
        title: "Fix authentication flow",
        github_number: 42,
        body: "This PR fixes the auth redirect bug.")

      prompt = described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true,
        issue: pr_issue
      )

      expect(prompt).not_to include("Issue Requirements")
      expect(prompt).to include("# Task")
      expect(prompt).to include("This PR fixes the auth redirect bug.")
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

  describe "service container sections" do
    subject(:prompt) do
      described_class.call(
        project: project,
        pr_number: 42,
        github_client: github_client,
        rebase_succeeded: true
      )
    end

    context "when project has no service containers" do
      it "includes environment constraints warning" do
        expect(prompt).to include("Environment Constraints")
        expect(prompt).to include("Do NOT attempt to install PostgreSQL")
        expect(prompt).to include("Do NOT run `bin/setup`")
      end

      it "tells the agent not to run database commands" do
        expect(prompt).to include("Do NOT run `bin/setup`, `db:prepare`, or `db:migrate`")
      end

      it "does not include available services section" do
        expect(prompt).not_to include("Available Services")
      end
    end

    context "when project has configured database containers" do
      let!(:service_container) { create(:service_container, account: project.account) }

      before do
        project.service_containers << service_container
      end

      it "includes available services section" do
        expect(prompt).to include("Available Services")
        expect(prompt).to include("DATABASE_URL")
      end

      it "does not include environment constraints warning" do
        expect(prompt).not_to include("Environment Constraints")
        expect(prompt).not_to include("Do NOT attempt to install PostgreSQL")
      end

      it "tells a Ruby project to run db:prepare" do
        expect(prompt).to include("Run `bin/rails db:prepare`")
        expect(prompt).to include("DATABASE_URL")
      end
    end

    context "when project has configured non-database service containers" do
      let!(:redis_container) { create(:service_container, :redis, account: project.account) }

      before do
        project.service_containers << redis_container
      end

      it "shows available services but still warns about missing database" do
        expect(prompt).to include("Available Services")
        expect(prompt).to include("REDIS_URL")
        expect(prompt).to include("Environment Constraints")
        expect(prompt).to include("Do NOT attempt to install PostgreSQL")
        expect(prompt).not_to include("Run `bin/rails db:prepare`")
      end
    end
  end

  describe "priority ordering" do
    it "orders priorities correctly with all sections present" do
      allow(github_client).to receive_messages(
        check_runs_for_ref: [ { name: "ci", conclusion: "failure", output_text: "failed" } ],
        review_threads: [ { id: "t1", is_resolved: false, comments: [ { body: "fix", path: "a.rb", line: 1, author: "r" } ] } ]
      )
      allow(github_client).to receive(:check_run_log).and_return("")
      allow(github_client).to receive(:recent_issue_comments)
        .with(project.full_name, 42, pages: 1)
        .and_return([ OpenStruct.new(user: OpenStruct.new(login: "trusteduser"), body: "comment") ])

      issue = create(:issue, project: project, title: "Issue", github_number: 1, body: "body")
      prompt = described_class.call(project: project, pr_number: 42, github_client: github_client, rebase_succeeded: false, issue: issue)

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

      expect(prompt).not_to include("CI Status: FAILING")
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
