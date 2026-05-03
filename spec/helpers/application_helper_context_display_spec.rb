# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper do
  describe "#issue_label_badge_classes" do
    it "uses GitHub-like styling for default priority labels" do
      project = build(:project)

      expect(helper.issue_label_badge_classes(project, "P0")).to include("bg-red-700 text-red-50")
      expect(helper.issue_label_badge_classes(project, "P1")).to include("bg-red-100 text-red-800")
      expect(helper.issue_label_badge_classes(project, "P2")).to include("bg-orange-100 text-orange-800")
      expect(helper.issue_label_badge_classes(project, "P3")).to include("bg-blue-100 text-blue-800")
    end

    it "uses GitHub-like styling for configured priority labels only" do
      project = build(:project, priority_labels: { "P1" => "urgent", "P2" => "high-touch", "P3" => "later" })

      expect(helper.issue_label_badge_classes(project, "urgent")).to include("bg-red-100 text-red-800")
      expect(helper.issue_label_badge_classes(project, "high-touch")).to include("bg-orange-100 text-orange-800")
      expect(helper.issue_label_badge_classes(project, "later")).to include("bg-blue-100 text-blue-800")
      expect(helper.issue_label_badge_classes(project, "bug")).to include("bg-gray-100 text-gray-600")
    end
  end

  describe "#agent_run_context_display" do
    # Use plain Structs instead of instance_double to avoid ActiveRecord column
    # lookups that require a database connection (these are pure view-layer tests).
    def stub_run(id: 1, **overrides) # rubocop:disable Metrics/MethodLength
      defaults = {
        id: id,
        "create_pr_goal?": false,
        "create_issue_goal?": false,
        "review_goal?": false,
        "enhance_issue_goal?": false,
        issue: nil,
        source_pull_request_number: nil,
        pull_request_number: nil,
        pull_request_url: nil,
        created_issue_url: nil,
        created_issue_number: nil,
        "finished?": false,
        project: nil
      }
      attrs = defaults.merge(overrides)
      Struct.new(*attrs.keys, keyword_init: true).new(**attrs)
    end

    def stub_issue(github_number:, github_url:, is_pull_request: false, title: nil)
      attrs = { github_number: github_number, github_url: github_url,
                "is_pull_request?": is_pull_request, title: title }
      Struct.new(*attrs.keys, keyword_init: true).new(**attrs)
    end

    def stub_project(github_url:)
      Struct.new(:github_url, keyword_init: true).new(github_url: github_url)
    end

    context "when create_pr goal with issue" do
      it "shows 'Issue #N' prefix for issues" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42", title: "Fix bug")
        run = stub_run("create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include("Issue #42")
        expect(result).not_to include("PR #42")
      end

      it "shows 'PR #N' prefix for pull requests" do
        issue = stub_issue(github_number: 10, github_url: "https://github.com/o/r/pull/10",
          is_pull_request: true, title: "Add feature")
        run = stub_run("create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #10")
        expect(result).not_to include("Issue #10")
      end

      it "includes title attribute for desktop tooltip" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42",
          title: "Fix the login bug")
        run = stub_run("create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include('title="Fix the login bug"')
      end

      it "renders the mobile info icon when tooltip is present" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42",
          title: "Fix the login bug")
        run = stub_run("create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include('data-controller="tooltip"')
        expect(result).to include('role="tooltip"')
        expect(result).to include("@media(hover:hover)_and_(pointer:fine)_and_(not_(any-pointer:coarse))")
      end

      it "omits the mobile info icon when tooltip is absent" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42", title: nil)
        run = stub_run("create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).not_to include('data-controller="tooltip"')
        expect(result).not_to include("@media(hover:hover)_and_(pointer:fine)_and_(not_(any-pointer:coarse))")
      end

      it "includes aria attributes on tooltip button" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42",
          title: "Fix bug")
        run = stub_run(id: 99, "create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include('aria-controls="tooltip_99"')
        expect(result).to include('aria-describedby="tooltip_99"')
        expect(result).to include('aria-label="Show context title"')
        expect(result).to include('aria-expanded="false"')
        expect(result).to include('aria-hidden="true"')
      end
    end

    context "when create_pr goal without issue" do
      it "shows source PR number as link when project has a github_url" do
        project = stub_project(github_url: "https://github.com/o/r")
        run = stub_run("create_pr_goal?": true, source_pull_request_number: 7, project: project)
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #7")
        expect(result).to include("https://github.com/o/r/pull/7")
        expect(result).to include("<a")
      end

      it "shows source PR number as text when project is nil" do
        run = stub_run("create_pr_goal?": true, source_pull_request_number: 7, project: nil)
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #7")
        expect(result).not_to include("<a")
      end

      it "shows pull request number as link" do
        run = stub_run("create_pr_goal?": true, pull_request_number: 3,
          pull_request_url: "https://github.com/o/r/pull/3")
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #3")
        expect(result).to include("https://github.com/o/r/pull/3")
      end

      it "shows placeholder when no context" do
        run = stub_run("create_pr_goal?": true)
        result = helper.agent_run_context_display(run)

        expect(result).to include("-")
      end
    end

    context "when create_issue goal" do
      it "shows link to created issue" do
        run = stub_run("create_issue_goal?": true,
          created_issue_url: "https://github.com/o/r/issues/42",
          created_issue_number: 42)
        result = helper.agent_run_context_display(run)

        expect(result).to include("Issue #42")
        expect(result).to include("https://github.com/o/r/issues/42")
      end

      it "shows 'Creating issue...' when pending" do
        run = stub_run("create_issue_goal?": true, "finished?": false)
        result = helper.agent_run_context_display(run)

        expect(result).to include("Creating issue")
      end

      it "shows placeholder when finished without issue" do
        run = stub_run("create_issue_goal?": true, "finished?": true)
        result = helper.agent_run_context_display(run)

        expect(result).to include("-")
      end
    end

    context "when review goal" do
      it "shows PR number as link when project has a github_url" do
        project = stub_project(github_url: "https://github.com/o/r")
        run = stub_run("review_goal?": true, source_pull_request_number: 15, project: project)
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #15")
        expect(result).to include("https://github.com/o/r/pull/15")
        expect(result).to include("<a")
      end

      it "shows PR number as text when project is nil" do
        run = stub_run("review_goal?": true, source_pull_request_number: 15, project: nil)
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #15")
        expect(result).not_to include("<a")
      end

      it "shows placeholder without PR number" do
        run = stub_run("review_goal?": true)
        result = helper.agent_run_context_display(run)

        expect(result).to include("-")
      end
    end

    context "when unknown goal" do
      it "shows placeholder" do
        run = stub_run
        result = helper.agent_run_context_display(run)

        expect(result).to include("-")
      end
    end
  end

  describe "#agent_run_goal_text" do
    def goal_text_run(issue: nil, custom_prompt: nil, review_goal: false, source_pull_request_number: nil)
      Struct.new(:issue, :custom_prompt, :source_pull_request_number, keyword_init: true) do
        define_method(:review_goal?) { review_goal }
      end.new(
        issue: issue,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number
      )
    end

    it "prefers the issue title over custom prompt text" do
      issue = Struct.new(:title, keyword_init: true).new(title: "Fix flaky webhook retry handling")
      run = goal_text_run(issue: issue, custom_prompt: "Rendered task instructions")

      expect(helper.agent_run_goal_text(run)).to eq(issue.title)
    end

    it "prefers the review pull request label over custom prompt text" do
      run = goal_text_run(custom_prompt: "Generated review instructions", review_goal: true,
        source_pull_request_number: 87)

      expect(helper.agent_run_goal_text(run)).to eq("Review pull request #87")
    end

    it "shows PR label for non-review runs with a source pull request number" do
      run = goal_text_run(custom_prompt: "Generated instructions", review_goal: false,
        source_pull_request_number: 42)

      expect(helper.agent_run_goal_text(run)).to eq("PR pull request #42")
    end

    it "falls back to redacted custom prompt text" do
      token = "ghp_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"
      run = goal_text_run(custom_prompt: "Investigate GITHUB_TOKEN=#{token}")

      expect(helper.agent_run_goal_text(run)).to include("[REDACTED:github_token]")
      expect(helper.agent_run_goal_text(run)).not_to include(token)
    end

    it "returns nil when no goal text is available" do
      run = goal_text_run

      expect(helper.agent_run_goal_text(run)).to be_nil
    end
  end
end
