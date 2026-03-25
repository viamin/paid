# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper do
  describe "#agent_run_context_display" do
    # Use plain Structs instead of instance_double to avoid ActiveRecord column
    # lookups that require a database connection (these are pure view-layer tests).
    def stub_run(id: 1, **overrides) # rubocop:disable Metrics/MethodLength
      defaults = {
        id: id,
        "create_pr_goal?": false,
        "create_issue_goal?": false,
        "review_goal?": false,
        issue: nil,
        source_pull_request_number: nil,
        pull_request_number: nil,
        pull_request_url: nil,
        created_issue_url: nil,
        created_issue_number: nil,
        "finished?": false
      }
      attrs = defaults.merge(overrides)
      Struct.new(*attrs.keys, keyword_init: true).new(**attrs)
    end

    def stub_issue(github_number:, github_url:, is_pull_request: false, title: nil)
      attrs = { github_number: github_number, github_url: github_url,
                "is_pull_request?": is_pull_request, title: title }
      Struct.new(*attrs.keys, keyword_init: true).new(**attrs)
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
        expect(result).to include("sm:hidden")
      end

      it "omits the mobile info icon when tooltip is absent" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42", title: nil)
        run = stub_run("create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).not_to include('data-controller="tooltip"')
        expect(result).not_to include("sm:hidden")
      end

      it "includes aria attributes on tooltip button" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42",
          title: "Fix bug")
        run = stub_run(id: 99, "create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include('aria-controls="tooltip_99"')
        expect(result).to include('aria-expanded="false"')
        expect(result).to include('aria-hidden="true"')
      end
    end

    context "when create_pr goal without issue" do
      it "shows source PR number as text" do
        run = stub_run("create_pr_goal?": true, source_pull_request_number: 7)
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #7")
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
      it "shows PR number" do
        run = stub_run("review_goal?": true, source_pull_request_number: 15)
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #15")
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
end
