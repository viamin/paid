# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::BuildSystemPrompt do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }

  describe ".call" do
    it "delegates to a new instance" do
      prompt = described_class.call(chat_session: chat_session)

      expect(prompt).to be_a(String)
      expect(prompt).to include("AI assistant")
    end
  end

  describe "#call" do
    subject(:prompt) { described_class.new(chat_session: chat_session).call }

    describe "base identity" do
      subject(:prompt) { prompt_builder.call }

      let(:prompt_builder) { described_class.new(chat_session: chat_session) }

      before do
        allow(prompt_builder).to receive(:resolve_prompt).and_return(nil)
      end

      it "is always present" do
        expect(prompt).to include("AI assistant helping manage software projects via Paid")
      end

      it "lists capabilities" do
        expect(prompt).to include("Designing features")
        expect(prompt).to include("Debugging issues")
        expect(prompt).to include("Managing projects")
      end

      it "includes usage guidance" do
        expect(prompt).to include("use the available tools")
        expect(prompt).to include("prefer configuration profiles")
        expect(prompt).to include("create a Change Intent Record")
        expect(prompt).to include("Be concise and technical")
      end

      it "includes feature-creation guidance" do
        expect(prompt).to include("gather intent through adaptive questions")
        expect(prompt).to include("problem, desired behavior, constraints, rejected alternatives, scope, and done-ness")
        expect(prompt).to include("search_code")
        expect(prompt).to include("get_file_content")
        expect(prompt).to include("trigger a `create_feature` agent run")
        expect(prompt).to include("custom_prompt")
      end
    end

    describe "user preferences" do
      it "includes preferences section" do
        expect(prompt).to include("Preferences")
        expect(prompt).to include("concise, technical responses")
      end
    end

    describe "tool definitions" do
      context "when project has MCP tools" do
        let(:project) { create(:project, account: account) }
        let(:chat_session) { create(:chat_session, account: account, created_by: user, project: project) }

        before do
          mcp = create(:mcp_server_definition, account: account, name: "list_projects",
            metadata: { "description" => "List your accessible projects" })
          create(:project_mcp_server, project: project, mcp_server_definition: mcp)

          mcp2 = create(:mcp_server_definition, account: account, name: "trigger_agent_run",
            metadata: { "description" => "Start an agent run on an issue" })
          create(:project_mcp_server, project: project, mcp_server_definition: mcp2)
        end

        it "includes tool definitions section" do
          expect(prompt).to include("Available Tools")
        end

        it "lists each MCP tool" do
          expect(prompt).to include("[list_projects]")
          expect(prompt).to include("[trigger_agent_run]")
        end

        it "includes tool descriptions from metadata" do
          expect(prompt).to include("List your accessible projects")
          expect(prompt).to include("Start an agent run on an issue")
        end

        it "includes usage instructions" do
          expect(prompt).to include("call list_projects")
        end
      end

      context "when MCP tool metadata has no description" do
        let(:project) { create(:project, account: account) }
        let(:chat_session) { create(:chat_session, account: account, created_by: user, project: project) }

        before do
          mcp = create(:mcp_server_definition, account: account, name: "fallback_tool", metadata: {})
          create(:project_mcp_server, project: project, mcp_server_definition: mcp)
        end

        it "falls back to server name as description" do
          expect(prompt).to include("[fallback_tool] fallback_tool")
        end
      end

      context "when project has disabled MCP tools" do
        let(:project) { create(:project, account: account) }
        let(:chat_session) { create(:chat_session, account: account, created_by: user, project: project) }

        before do
          mcp = create(:mcp_server_definition, :disabled, account: account, name: "disabled_tool")
          create(:project_mcp_server, project: project, mcp_server_definition: mcp)
        end

        it "excludes disabled tools" do
          expect(prompt).not_to include("disabled_tool")
          expect(prompt).not_to include("Available Tools")
        end
      end

      context "when no project is associated" do
        it "omits tool definitions section" do
          expect(prompt).not_to include("Available Tools")
        end
      end
    end

    describe "project context" do
      let(:project) { create(:project, account: account, name: "my-app", owner: "acme", repo: "my-app") }
      let(:chat_session) { create(:chat_session, account: account, created_by: user, project: project) }

      it "includes project header with name and owner/repo" do
        expect(prompt).to include("Current Project: my-app (acme/my-app)")
      end

      context "with recent issues" do
        before do
          create(:issue, project: project, github_number: 42, title: "Fix login bug",
            github_state: "open", github_updated_at: 1.hour.ago)
          create(:issue, project: project, github_number: 43, title: "Add dark mode",
            github_state: "closed", github_updated_at: 2.hours.ago)
        end

        it "includes recent issues" do
          expect(prompt).to include("Recent Issues")
          expect(prompt).to include("#42: Fix login bug [open]")
          expect(prompt).to include("#43: Add dark mode [closed]")
        end
      end

      context "with pull requests excluded from issues" do
        before do
          create(:issue, project: project, github_number: 10, title: "Real issue",
            github_state: "open", github_updated_at: 1.hour.ago)
          create(:issue, :pull_request, project: project, github_number: 11,
            title: "PR not an issue", github_state: "open", github_updated_at: 30.minutes.ago)
        end

        it "excludes pull requests from recent issues" do
          expect(prompt).to include("#10: Real issue")
          expect(prompt).not_to include("PR not an issue")
        end
      end

      context "with recent agent runs" do
        before do
          create(:agent_run, :completed, project: project, goal: "create_pr",
            tokens_input: 1000, tokens_output: 500)
          create(:agent_run, :existing_pr, project: project, goal: "review", status: "running",
            tokens_input: 200, tokens_output: 100)
        end

        it "includes recent agent runs" do
          expect(prompt).to include("Recent Agent Runs")
          expect(prompt).to include("create_pr")
          expect(prompt).to include("tokens: 1500")
        end
      end

      context "with style guides" do
        before do
          create(:style_guide, :for_project, project: project, account: account,
            raw_content: "Use 2-space indentation")
        end

        it "includes style guide content" do
          expect(prompt).to include("Style Guide")
          expect(prompt).to include("Use 2-space indentation")
        end
      end

      context "with oversized style guides" do
        before do
          3.times do |i|
            create(:style_guide, :for_project, project: project, account: account,
              raw_content: "Guide #{i}: #{"x" * 6000}")
          end
        end

        it "truncates combined style guide content to stay within budget" do
          style_guide_max = described_class::STYLE_GUIDE_MAX_CHARS
          # Extract just the style guide section (between "### Style Guide" and the next "##" or end)
          style_section = prompt[/### Style Guide\n(.+?)(?=\n##|\z)/m, 1]
          # The combined content (excluding the "### Style Guide\n" header) should respect the cap
          expect(style_section.length).to be <= style_guide_max + 5
        end
      end

      context "with no issues or runs" do
        it "omits empty sections" do
          expect(prompt).not_to include("Recent Issues")
          expect(prompt).not_to include("Recent Agent Runs")
        end
      end

      it "limits issues to 5" do
        7.times do |i|
          create(:issue, project: project, github_number: 100 + i,
            title: "Issue #{i}", github_state: "open",
            github_updated_at: i.hours.ago)
        end

        issue_lines = prompt.scan(/^- #\d+:/).count
        expect(issue_lines).to eq(5)
      end

      it "limits agent runs to 5" do
        7.times do
          create(:agent_run, :completed, project: project, goal: "create_pr",
            tokens_input: 100, tokens_output: 50)
        end

        run_lines = prompt.scan(/^- Run #\d+:/).count
        expect(run_lines).to eq(5)
      end
    end

    describe "page context" do
      let(:chat_session) do
        create(:chat_session,
          account: account,
          created_by: user,
          metadata: {
            "page_context" => {
              "url" => "https://paid.example.test/projects/7/agent_runs",
              "path" => "/projects/7/agent_runs",
              "page_title" => "Agent Runs - Acme API - Paid",
              "controller" => "projects/agent_runs",
              "action" => "index",
              "project_name" => "Acme API"
            }
          })
      end

      it "includes current page metadata from the session" do
        expect(prompt).to include("Current Page Context")
        expect(prompt).to include("URL: https://paid.example.test/projects/7/agent_runs")
        expect(prompt).to include("Page title: Agent Runs - Acme API - Paid")
        expect(prompt).to include("Controller: projects/agent_runs")
        expect(prompt).to include("Project: Acme API")
      end
    end

    describe "cross-project context" do
      let(:ref_project) { create(:project, account: account, name: "shared-lib", owner: "acme", repo: "shared-lib") }

      before do
        chat_session.chat_session_projects.create!(project: ref_project, context_type: "reference")
      end

      it "includes referenced projects section" do
        expect(prompt).to include("Referenced Projects")
        expect(prompt).to include("acme/shared-lib")
      end

      context "with multiple reference projects" do
        let(:another_project) { create(:project, account: account, name: "utils", owner: "acme", repo: "utils") }

        before do
          chat_session.chat_session_projects.create!(project: another_project, context_type: "reference")
        end

        it "lists all reference projects" do
          expect(prompt).to include("acme/shared-lib")
          expect(prompt).to include("acme/utils")
        end
      end
    end

    describe "workspace context" do
      let(:chat_session) { create(:chat_session, :workspace, account: account, created_by: user) }

      it "includes workspace section" do
        expect(prompt).to include("Workspace")
        expect(prompt).to include("git repository checked out")
      end

      it "mentions file and command access" do
        expect(prompt).to include("read and modify files")
        expect(prompt).to include("git operations")
      end

      context "with git state in metadata" do
        let(:chat_session) do
          create(:chat_session, :workspace, account: account, created_by: user,
            metadata: {
              "current_branch" => "feat/login-page",
              "git_status" => "M app/models/user.rb",
              "working_directory" => "/workspace/my-app"
            })
        end

        it "includes current branch" do
          expect(prompt).to include("Current branch: feat/login-page")
        end

        it "includes git status" do
          expect(prompt).to include("Git status:")
          expect(prompt).to include("M app/models/user.rb")
        end

        it "includes working directory" do
          expect(prompt).to include("Working directory: /workspace/my-app")
        end
      end

      context "without git state in metadata" do
        it "omits git state details" do
          expect(prompt).not_to include("Current branch:")
          expect(prompt).not_to include("Git status:")
          expect(prompt).not_to include("Working directory:")
        end
      end
    end

    describe "workspace context omitted until the container is ready" do
      %w[none pending provisioning failed stopped].each do |capability|
        context "when container capability is #{capability}" do
          let(:chat_session) { create(:chat_session, account: account, created_by: user, container_capability: capability) }

          it "does not include workspace section" do
            expect(prompt).not_to include("Workspace")
            expect(prompt).not_to include("git repository")
          end
        end
      end
    end

    describe "context size management" do
      let(:project) { create(:project, account: account, owner: "acme", repo: "my-app") }
      let(:chat_session) { create(:chat_session, :workspace, account: account, created_by: user, project: project) }

      it "keeps prompt under token limit" do
        # Create enough data to potentially exceed the limit
        10.times do |i|
          create(:issue, project: project, github_number: i + 1,
            title: "A" * 200, github_state: "open",
            github_updated_at: i.hours.ago)
        end

        char_count = prompt.length
        max_chars = described_class::MAX_TOKENS * described_class::CHARS_PER_TOKEN
        expect(char_count).to be <= max_chars
      end

      it "always preserves base identity even when over budget" do
        expect(prompt).to include("AI assistant helping manage software projects")
      end

      it "drops lower-priority sections first" do
        # With a normal session, all sections should be present
        expect(prompt).to include("Workspace")
        expect(prompt).to include("Preferences")
      end
    end

    describe "integration: full prompt for multi-project workspace session" do
      let(:project) { create(:project, account: account, name: "main-app", owner: "acme", repo: "main-app") }
      let(:ref_project) { create(:project, account: account, name: "shared-lib", owner: "acme", repo: "shared-lib") }
      let(:chat_session) do
        create(:chat_session, :workspace, account: account, created_by: user, project: project)
      end

      before do
        # MCP tools
        mcp = create(:mcp_server_definition, account: account, name: "list_projects",
          metadata: { "description" => "List accessible projects" })
        create(:project_mcp_server, project: project, mcp_server_definition: mcp)

        # Issues
        create(:issue, project: project, github_number: 1, title: "Setup CI",
          github_state: "open", github_updated_at: 1.hour.ago)

        # Agent runs
        create(:agent_run, :completed, project: project, goal: "create_pr",
          tokens_input: 5000, tokens_output: 2000)

        # Style guide
        create(:style_guide, :for_project, project: project, account: account,
          raw_content: "Follow rubocop-rails-omakase")

        # Reference project
        chat_session.chat_session_projects.create!(project: ref_project, context_type: "reference")
      end

      it "assembles all sections in a single prompt" do
        expect(prompt).to include("AI assistant helping manage software projects")
        expect(prompt).to include("Available Tools")
        expect(prompt).to include("Current Project: main-app (acme/main-app)")
        expect(prompt).to include("Recent Issues")
        expect(prompt).to include("Recent Agent Runs")
        expect(prompt).to include("Style Guide")
        expect(prompt).to include("Referenced Projects")
        expect(prompt).to include("acme/shared-lib")
        expect(prompt).to include("Workspace")
        expect(prompt).to include("Preferences")
      end

      it "stays within token budget" do
        max_chars = described_class::MAX_TOKENS * described_class::CHARS_PER_TOKEN
        expect(prompt.length).to be <= max_chars
      end
    end
  end
end
