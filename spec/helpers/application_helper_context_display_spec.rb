# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, :no_db do
  def stub_priority_project(priority_labels: {})
    Struct.new(:priority_labels, keyword_init: true) do
      def priority_label_for(tier)
        effective_priority_labels.fetch(tier, tier)
      end

      def effective_priority_labels
        Project::DEFAULT_PRIORITY_LABELS.merge(priority_labels || {})
      end
    end.new(priority_labels: priority_labels)
  end

  describe "#issue_label_badge_classes" do
    it "uses GitHub-like styling for default priority labels" do
      project = stub_priority_project

      expect(helper.issue_label_badge_classes(project, "P0")).to include("bg-red-700 text-red-50")
      expect(helper.issue_label_badge_classes(project, "P1")).to include("bg-red-100 text-red-800")
      expect(helper.issue_label_badge_classes(project, "P2")).to include("bg-orange-100 text-orange-800")
      expect(helper.issue_label_badge_classes(project, "P3")).to include("bg-blue-100 text-blue-800")
    end

    it "uses GitHub-like styling for configured priority labels only" do
      project = stub_priority_project(priority_labels: { "P1" => "urgent", "P2" => "high-touch", "P3" => "later" })

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
        "analyze_issue_goal?": false,
        issue: nil,
        custom_prompt: nil,
        source_pull_request_number: nil,
        source_pull_request_record: nil,
        pull_request_number: nil,
        pull_request_url: nil,
        created_issue_url: nil,
        created_issue_number: nil,
        created_issue_record: nil,
        "finished?": false,
        "running?": false,
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

        expect(result).to include("<details")
        expect(result).to include('role="tooltip"')
        expect(result).to include("@media(hover:hover)_and_(pointer:fine)_and_(not_(any-pointer:coarse))")
      end

      it "reveals the tooltip on keyboard focus even when the info icon is hidden on fine-pointer devices" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42",
          title: "Fix the login bug")
        run = stub_run("create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        # The disclosure triangle is hidden on hover-capable fine-pointer devices, but the
        # tooltip content must still be reachable by focusing the underlying link/span so
        # keyboard users on desktop are not locked out (see #3517 review feedback).
        expect(result).to include("group-focus-within:block")
      end

      it "falls back to the issue label tooltip when the issue title is absent" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42", title: nil)
        run = stub_run("create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include('title="Issue #42"')
        expect(result).to include("<details")
        expect(result).to include("@media(hover:hover)_and_(pointer:fine)_and_(not_(any-pointer:coarse))")
      end

      it "includes aria attributes on tooltip summary" do
        issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42",
          title: "Fix bug")
        run = stub_run(id: 99, "create_pr_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include('aria-label="Show context details"')
        expect(result).to include('id="context_99"')
        expect(result).to include('role="tooltip"')
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

      it "includes a tooltip for source PR context without a custom prompt" do
        source_pr = stub_issue(github_number: 7, github_url: "https://github.com/o/r/pull/7",
          is_pull_request: true, title: "Tighten tooltip coverage")
        project = stub_project(github_url: "https://github.com/o/r")
        run = stub_run("create_pr_goal?": true, source_pull_request_number: 7,
          source_pull_request_record: source_pr, project: project)
        result = helper.agent_run_context_display(run)

        expect(result).to include('title="Tighten tooltip coverage"')
        expect(result).to include("<details")
      end

      it "shows source PR number as text when project is nil" do
        run = stub_run("create_pr_goal?": true, source_pull_request_number: 7, project: nil)
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #7")
        expect(result).not_to include("<a")
      end

      it "falls back to the PR label when no richer tooltip is available" do
        project = stub_project(github_url: "https://github.com/o/r")
        run = stub_run("create_pr_goal?": true, source_pull_request_number: 7, project: project)
        result = helper.agent_run_context_display(run)

        expect(result).to include('title="PR #7"')
      end

      it "shows pull request number as link" do
        run = stub_run("create_pr_goal?": true, pull_request_number: 3,
          pull_request_url: "https://github.com/o/r/pull/3")
        result = helper.agent_run_context_display(run)

        expect(result).to include("PR #3")
        expect(result).to include("https://github.com/o/r/pull/3")
        expect(result).to include('title="PR #3"')
      end

      it "shows truncated prompt text with tooltip when no issue or PR context exists" do
        run = stub_run("create_pr_goal?": true, custom_prompt: "Refactor the flaky dashboard queue preview rows")
        result = helper.agent_run_context_display(run)

        expect(result).to include("Refactor the flaky dashboard queue preview rows")
        expect(result).to include("text-gray-700")
      end

      it "truncates long prompts to 60 characters in the displayed label" do
        long_prompt = "Refactor the entire authentication subsystem to use OAuth2 with PKCE flow instead of session cookies"
        run = stub_run("create_pr_goal?": true, custom_prompt: long_prompt)
        result = helper.agent_run_context_display(run)

        truncated = long_prompt.truncate(60)
        # The truncated version appears as visible text
        expect(result).to include(truncated)
        # The full prompt is NOT shown as the visible label (it ends with "...")
        expect(truncated).to end_with("...")
        # A longer version appears in the tooltip for hover context
        expect(result).to include("title=")
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

      it "includes a tooltip for created issue context without a custom prompt" do
        created_issue = stub_issue(github_number: 42, github_url: "https://github.com/o/r/issues/42",
          title: "Document tooltip behavior")
        run = stub_run("create_issue_goal?": true,
          created_issue_url: "https://github.com/o/r/issues/42",
          created_issue_number: 42,
          created_issue_record: created_issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include('title="Document tooltip behavior"')
        expect(result).to include("<details")
      end

      it "falls back to the issue label when no richer created issue tooltip is available" do
        run = stub_run("create_issue_goal?": true,
          created_issue_url: "https://github.com/o/r/issues/42",
          created_issue_number: 42)
        result = helper.agent_run_context_display(run)

        expect(result).to include('title="Issue #42"')
      end

      it "shows truncated prompt text with tooltip when available and no created issue" do
        run = stub_run("create_issue_goal?": true, custom_prompt: "Add a login timeout feature")
        result = helper.agent_run_context_display(run)

        expect(result).to include("Add a login timeout feature")
        expect(result).to include("text-gray-700")
      end

      it "truncates long prompts to 60 characters in the displayed label" do
        long_prompt = "Create a comprehensive issue documenting all the edge cases found during the security audit review"
        run = stub_run("create_issue_goal?": true, custom_prompt: long_prompt)
        result = helper.agent_run_context_display(run)

        truncated = long_prompt.truncate(60)
        # The truncated version appears as visible text
        expect(result).to include(truncated)
        # The full prompt is NOT shown as the visible label (it ends with "...")
        expect(truncated).to end_with("...")
        # A longer version appears in the tooltip for hover context
        expect(result).to include("title=")
      end

      it "shows 'Creating issue...' when in progress without custom prompt" do
        run = stub_run("create_issue_goal?": true, "running?": true)
        result = helper.agent_run_context_display(run)

        expect(result).to include("Creating issue")
      end

      it "shows 'Creating issue...' when paused without custom prompt" do
        run = stub_run("create_issue_goal?": true, "running?": false, "finished?": false)
        result = helper.agent_run_context_display(run)

        expect(result).to include("Creating issue")
      end

      it "shows placeholder when finished and no context available" do
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

      it "includes a tooltip for review PR context without a custom prompt" do
        source_pr = stub_issue(github_number: 15, github_url: "https://github.com/o/r/pull/15",
          is_pull_request: true, title: "Review the tooltip helper update")
        project = stub_project(github_url: "https://github.com/o/r")
        run = stub_run("review_goal?": true, source_pull_request_number: 15,
          source_pull_request_record: source_pr, project: project)
        result = helper.agent_run_context_display(run)

        expect(result).to include('title="Review the tooltip helper update"')
        expect(result).to include("<details")
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

    context "when analyze_issue goal" do
      it "shows issue link when issue is present" do
        issue = stub_issue(github_number: 55, github_url: "https://github.com/o/r/issues/55", title: "Investigate flaky test")
        run = stub_run("analyze_issue_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include("Issue #55")
        expect(result).to include("https://github.com/o/r/issues/55")
      end

      it "falls back to the issue label tooltip when the issue title is absent" do
        issue = stub_issue(github_number: 55, github_url: "https://github.com/o/r/issues/55", title: nil)
        run = stub_run("analyze_issue_goal?": true, issue: issue)
        result = helper.agent_run_context_display(run)

        expect(result).to include('title="Issue #55"')
        expect(result).to include("<details")
      end

      it "shows placeholder when no issue" do
        run = stub_run("analyze_issue_goal?": true)
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
    def goal_text_run(goal:)
      Struct.new(:goal, keyword_init: true).new(goal: goal)
    end

    it "returns 'PR Creation' for create_pr goal" do
      run = goal_text_run(goal: "create_pr")
      expect(helper.agent_run_goal_text(run)).to eq("PR Creation")
    end

    it "returns 'Issue Creation' for create_issue goal" do
      run = goal_text_run(goal: "create_issue")
      expect(helper.agent_run_goal_text(run)).to eq("Issue Creation")
    end

    it "returns 'Code Review' for review goal" do
      run = goal_text_run(goal: "review")
      expect(helper.agent_run_goal_text(run)).to eq("Code Review")
    end

    it "returns 'Issue Enhancement' for enhance_issue goal" do
      run = goal_text_run(goal: "enhance_issue")
      expect(helper.agent_run_goal_text(run)).to eq("Issue Enhancement")
    end

    it "returns 'Issue Analysis' for analyze_issue goal" do
      run = goal_text_run(goal: "analyze_issue")
      expect(helper.agent_run_goal_text(run)).to eq("Issue Analysis")
    end

    it "returns 'LID Planning' for lid_planning goal" do
      run = goal_text_run(goal: "lid_planning")
      expect(helper.agent_run_goal_text(run)).to eq("LID Planning")
    end

    it "returns 'Feature Creation' for create_feature goal" do
      run = goal_text_run(goal: "create_feature")
      expect(helper.agent_run_goal_text(run)).to eq("Feature Creation")
    end

    it "titleizes unknown goal values" do
      run = goal_text_run(goal: "some_new_goal")
      expect(helper.agent_run_goal_text(run)).to eq("Some New Goal")
    end

    it "covers every goal in AgentRun::GOALS" do
      expect(ApplicationHelper::AGENT_RUN_GOAL_LABELS.keys).to match_array(AgentRun::GOALS)
    end
  end

  describe "#agent_run_goal_display" do
    def goal_display_run(id:, goal:)
      Struct.new(:id, :goal, keyword_init: true).new(id: id, goal: goal)
    end

    it "renders the goal label without a tooltip" do
      run = goal_display_run(id: 42, goal: "create_pr")
      result = helper.agent_run_goal_display(run)

      expect(result).to include("PR Creation")
      expect(result).not_to include("title=")
      expect(result).not_to include("<details")
      expect(result).not_to include('role="tooltip"')
    end

    it "titleizes unknown goal values in the rendered label" do
      run = goal_display_run(id: 7, goal: "some_new_goal")
      result = helper.agent_run_goal_display(run)

      expect(result).to include("Some New Goal")
    end
  end

  describe "#agent_run_focus_badge" do
    def focus_run(id:, focus:)
      Struct.new(:id, :focus, keyword_init: true).new(id: id, focus: focus)
    end

    it "returns nil for general focus" do
      run = focus_run(id: 1, focus: "general")
      expect(helper.agent_run_focus_badge(run)).to be_nil
    end

    it "returns nil when the run object does not expose focus" do
      run = Struct.new(:id, keyword_init: true).new(id: 1)
      expect(helper.agent_run_focus_badge(run)).to be_nil
    end

    it "returns a badge with the configured label for known non-general focus" do
      run = focus_run(id: 2, focus: "review_feedback")
      result = helper.agent_run_focus_badge(run)

      expect(result).to include("Review Feedback")
      expect(result).to include("bg-violet-100")
      expect(result).to include('title="Work type: Review Feedback"')
    end

    it "titleizes unknown focus values into a badge" do
      run = focus_run(id: 3, focus: "future_focus")
      result = helper.agent_run_focus_badge(run)

      expect(result).to include("Future Focus")
    end
  end
end
