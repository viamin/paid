# frozen_string_literal: true

require "rails_helper"

# @spec CREATE-FEATURE-001
# @spec CREATE-FEATURE-002
# @spec CREATE-FEATURE-003
# @spec CREATE-FEATURE-004
#
# End-to-end integration tests for the create_feature goal (RDR-053).
# Covers the four entry paths — chat, run, needs-input, and LID —
# plus agent run lifecycle validation, docs-only PR guard, contract
# validation, and issue tree structure.
RSpec.describe "CreateFeature E2E", type: :model do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }
  let(:runner) { create(:runner, user: project.created_by) }

  let(:complete_feature_brief) do
    {
      "title" => "Add dark mode",
      "problem" => "Users want a dark theme to reduce eye strain at night",
      "desired_behavior" => "When the user toggles dark mode, the UI switches to a dark color palette",
      "constraints" => [ "Must support system preference detection", "No flash of light theme on load" ],
      "rejected_alternatives" => [ "CSS-only variables" ],
      "scope" => { "in" => [ "Color palette", "Toggle", "Persistence" ], "out" => [ "Syntax highlighting" ] },
      "done_criteria" => "Dark mode is toggleable, persists, and passes visual regression tests",
      "lid_requested" => false,
      "target_rdr_number" => nil
    }
  end

  let(:sparse_feature_brief) do
    {
      "title" => "Add dark mode",
      "problem" => "Users want dark mode"
    }
  end

  # ---------------------------------------------------------------------------
  # Chat path
  # ---------------------------------------------------------------------------
  describe "chat path" do
    let(:chat_session) { create(:chat_session, account: account, created_by: user) }

    it "includes general system guidance in the system prompt" do
      prompt = ChatSessions::BuildSystemPrompt.call(chat_session: chat_session)

      expect(prompt).to include("AI assistant helping manage software projects via Paid")
      expect(prompt).to include("Designing features and discussing implementation approaches")
      expect(prompt).to include("use the available tools")
    end

    it "chat session with a primary project includes project name and feature guidance" do
      session = ChatSessions::Create.call(account: account, user: user, project_id: project.id)

      expect(session).to be_persisted
      expect(session.project).to eq(project)
      system_msg = session.messages.find_by(role: "system")
      expect(system_msg.content).to include(project.name)
      expect(system_msg.content).to include("Designing features and discussing implementation approaches")
    end
  end

  # ---------------------------------------------------------------------------
  # Run path (direct trigger)
  # ---------------------------------------------------------------------------
  describe "run path" do
    it "creates a queued create_feature run with a complete feature brief" do
      agent_run = create(
        :agent_run,
        :create_feature_goal,
        project: project,
        issue: nil,
        runner: runner,
        external_metadata: { "feature_brief" => complete_feature_brief }
      )

      expect(agent_run).to be_persisted
      expect(agent_run.goal).to eq("create_feature")
      expect(agent_run.status).to eq("queued")
      expect(agent_run.repo_cloned?).to be true
    end

    it "prompt_for_goal builds a prompt from the feature brief" do
      agent_run = build(
        :agent_run,
        :create_feature_goal,
        project: project,
        issue: nil,
        custom_prompt: nil,
        external_metadata: { "feature_brief" => complete_feature_brief }
      )

      prompt = agent_run.send(:prompt_for_goal)

      expect(prompt).to include(project.full_name)
      expect(prompt).to include("Add dark mode")
      expect(prompt).to include("dark theme")
    end

    it "raises when create_feature run has no feature brief" do
      agent_run = build(:agent_run, :create_feature_goal, custom_prompt: nil, external_metadata: {})

      expect { agent_run.send(:prompt_for_goal) }.to raise_error(ArgumentError, /feature_brief/)
    end

    it "does not require an issue, custom_prompt, or source PR (prompt is derived)" do
      agent_run = build(:agent_run, :create_feature_goal, issue: nil, custom_prompt: nil)

      expect(agent_run).to be_valid
    end

    it "is included in AgentRun::GOALS" do
      expect(AgentRun::GOALS).to include("create_feature")
    end

    it "is in the queue priority goals" do
      expect(AgentRun::QUEUE_GOAL_PRIORITY_GOALS).to include("create_feature")
    end
  end

  # ---------------------------------------------------------------------------
  # Needs-input path
  # ---------------------------------------------------------------------------
  describe "needs-input path" do
    let(:feature_issue) do
      create(:issue, :needs_input, project: project,
             title: "[Feature] Add dark mode", body: "Need dark mode",
             github_number: 42)
    end

    before do
      allow(Prompts::BuildForCreateFeature).to receive(:call).and_return("feature prompt")
      stub_request(:post, %r{api\.github\.com/repos/.*/issues/.*/comments}).to_return(status: 200, body: "{}")
      stub_request(:post, %r{api\.github\.com/repos/.*/issues/.*/labels}).to_return(status: 200, body: "[]")
    end

    it "pauses when feature brief is sparse" do
      agent_run = create(
        :agent_run, :queued, :create_feature_goal,
        project: project, issue: feature_issue,
        external_metadata: { "feature_brief" => sparse_feature_brief }
      )

      activity = Activities::CreateAgentRunActivity.new
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:paused]).to be true
      expect(agent_run.reload.status).to eq("paused")
    end

    it "persists clarifying questions locally after pausing" do
      agent_run = create(
        :agent_run, :queued, :create_feature_goal,
        project: project, issue: feature_issue,
        external_metadata: { "feature_brief" => sparse_feature_brief }
      )

      activity = Activities::CreateAgentRunActivity.new
      activity.execute(agent_run_id: agent_run.id)

      expect(feature_issue.reload.needs_input_questions).to be_an(Array)
      expect(feature_issue.needs_input_questions).to include(
        a_string_matching(/desired behavior/)
      )
    end

    it "does not pause when feature brief has all required fields" do
      agent_run = create(
        :agent_run, :queued, :create_feature_goal,
        project: project, issue: feature_issue,
        external_metadata: { "feature_brief" => complete_feature_brief }
      )

      activity = Activities::CreateAgentRunActivity.new
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:paused]).to be_falsey
    end

    context "when resuming after needs-input" do
      let(:clear_client) do
        instance_double(GithubClient,
          remove_label_from_issue: nil,
          issue_comments: [])
      end
      let(:paused_run) do
        create(
          :agent_run, :create_feature_goal,
          project: project, issue: feature_issue,
          status: "paused",
          external_metadata: {
            "feature_brief" => { "title" => "Add dark mode", "problem" => "Need dark theme" }
          }
        )
      end

      before do
        allow(project).to receive(:client).and_return(clear_client)
        allow(ProcessRunQueueJob).to receive(:perform_later)
      end


      it "resumes the paused create_feature run when needs_input is cleared" do
        expect {
          ClarifyingQuestions::ClearNeedsInput.call(project: project, issue: feature_issue)
        }.to change { paused_run.reload.status }.from("paused").to("queued")
      end

      it "logs the resume event" do
        run_id = paused_run.id
        allow(Rails.logger).to receive(:info).and_call_original

        ClarifyingQuestions::ClearNeedsInput.call(project: project, issue: feature_issue)

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "agent_execution.create_feature_needs_input_answered",
            agent_run_id: run_id
          )
        )
      end
    end

    it "dashboard needs-input queue includes create_feature issues with local questions" do
      # Ensure the project is auto-pick enabled so it appears in the queue.
      project.update!(auto_pick_enabled: true)
      feature_issue.update!(needs_input_questions: [ "What is the desired behavior?" ])
      feature_issue.update!(paid_state: "needs_input", github_state: "open", is_pull_request: false)

      result = Dashboard::NeedsInputQueue.call(user: project.created_by, project: project)

      matching = result.select { |e| e.issue == feature_issue }
      expect(matching).not_to be_empty, "Expected feature_issue #{feature_issue.id} in dashboard queue but got #{result.map { |e| e.issue&.id }}"
      expect(matching.first.questions).to include("What is the desired behavior?")
    end
  end

  # ---------------------------------------------------------------------------
  # LID path
  # ---------------------------------------------------------------------------
  describe "LID path" do
    let(:lid_project) { create(:project, lid_mode: "full", account: account) }
    let(:lid_runner) { create(:runner, user: lid_project.created_by) }
    let(:initiating_user) { create(:user, account: lid_project.account) }

    it "receives the full LID contract in prompt injection" do
      prompt = Lid::InjectIntoPrompt.call(
        prompt: "build feature",
        project: lid_project,
        goal: "create_feature"
      )

      expect(prompt).to include("@spec")
      expect(prompt).to include("bin/coherence-check.mjs")
    end

    it "chains into lid_planning when lid_mode is set" do
      agent_run = create(
        :agent_run, :create_feature_goal, :completed,
        project: lid_project,
        runner: lid_runner,
        initiating_user: initiating_user
      )

      activity = Activities::ChainLidPlanningActivity.new

      expect {
        result = activity.execute(
          agent_run_id: agent_run.id,
          plan_doc_source: "https://github.com/example/repo/pull/42"
        )
        expect(result[:queued]).to be true
      }.to have_enqueued_job(ProcessRunQueueJob)

      followup = AgentRun.find_by(goal: "lid_planning", project: lid_project)
      expect(followup).to be_present
      expect(followup.status).to eq("queued")
      expect(followup.plan_doc_source).to eq("https://github.com/example/repo/pull/42")
      expect(followup.trigger_type).to eq("automatic")
      expect(followup.auto_pick).to be true
    end

    it "skips chaining when project is not LID-enabled" do
      agent_run = create(
        :agent_run, :create_feature_goal, :completed,
        project: project,  # non-LID
        runner: runner,
        initiating_user: user
      )

      activity = Activities::ChainLidPlanningActivity.new
      result = activity.execute(
        agent_run_id: agent_run.id,
        plan_doc_source: "PR #1"
      )

      expect(result).to eq(skipped: true, reason: "lid_mode_not_set")
      expect(AgentRun.where(project: project, goal: "lid_planning")).to be_empty
    end

    it "skips chaining when active lid_planning already exists" do
      create(:agent_run, :lid_planning_goal, project: lid_project, status: "queued")
      agent_run = create(
        :agent_run, :create_feature_goal, :completed,
        project: lid_project, runner: lid_runner, initiating_user: initiating_user
      )

      activity = Activities::ChainLidPlanningActivity.new
      result = activity.execute(
        agent_run_id: agent_run.id,
        plan_doc_source: "PR #1"
      )

      expect(result).to eq(skipped: true, reason: "active_lid_planning_exists")
    end
  end

  # ---------------------------------------------------------------------------
  # Agent run lifecycle validation
  # ---------------------------------------------------------------------------
  describe "agent run lifecycle" do
    it "transitions through queued → running → completed" do
      agent_run = create(
        :agent_run, :create_feature_goal,
        project: project, runner: runner,
        external_metadata: { "feature_brief" => complete_feature_brief }
      )

      expect(agent_run.status).to eq("queued")
      expect(agent_run.create_feature_goal?).to be true

      agent_run.start!
      expect(agent_run.reload.status).to eq("running")

      agent_run.complete!
      expect(agent_run.reload.status).to eq("completed")
    end

    it "validate prompt source exemption for create_feature" do
      agent_run = build(:agent_run, :create_feature_goal, issue: nil, custom_prompt: nil)

      expect(agent_run).to be_valid
      expect(agent_run.errors[:base]).to be_empty
    end

    it "always clones the repo for create_feature runs" do
      agent_run = build(:agent_run, :create_feature_goal)

      expect(agent_run.repo_cloned?).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # Docs-only PR guard + contract validation
  # ---------------------------------------------------------------------------
  describe "docs-only PR guard" do
    let(:rdr_path) { "docs/rdrs/RDR-099-add-dark-mode.md" }
    let(:feature_agent_run) do
      create(
        :agent_run, :with_git_context, :create_feature_goal,
        project: project, issue: nil,
        external_metadata: { "feature_brief" => complete_feature_brief }
      )
    end
    let(:valid_rdr_body) do
      <<~MARKDOWN
        # RDR-099: Add Dark Mode

        ## Metadata

        - Date: 2026-08-11

        ## Problem Statement

        Users want dark mode.

        ## Context

        The app uses ERB.

        ## Research Findings

        We read the codebase.

        ## Proposed Solution

        Add CSS variables.

        ## Alternatives Considered

        CSS-only.

        ## Trade-offs and Consequences

        Maintenance overhead.

        ## Rollout Guard

        Feature flag: dark_mode, default off.

        ## Implementation Plan

        Three phases.

        ## Validation

        Visual regression tests.
      MARKDOWN
    end

    let(:valid_index_body) do
      "| [RDR-099](RDR-099-add-dark-mode.md) | Add Dark Mode | Draft | P1 |"
    end

    it "allows docs/rdrs/ files without raising" do
      activity = Activities::CreatePullRequestActivity.new
      client = instance_double(GithubClient)

      allow(client).to receive_messages(
        compare_changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        create_pull_request: { "number" => 42, "html_url" => "https://github.com/example/repo/pull/42" }
      )
      allow(client).to receive(:file_content)
        .with(project.full_name, path: rdr_path, ref: feature_agent_run.result_commit_sha)
        .and_return(valid_rdr_body)
      allow(client).to receive(:file_content)
        .with(project.full_name, path: "docs/rdrs/README.md", ref: feature_agent_run.result_commit_sha)
        .and_return(valid_index_body)

      feature_agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")

      expect {
        activity.send(
          :validate_create_feature_changed_files!,
          feature_agent_run, client
        )
      }.not_to raise_error
    end

    it "rejects code files outside docs/rdrs/" do
      activity = Activities::CreatePullRequestActivity.new
      client = instance_double(GithubClient)

      allow(client).to receive(:compare_changed_files).and_return([ "app/models/foo.rb" ])

      feature_agent_run.update!(result_commit_sha: "abc123def456789012345678901234567890abcd")

      expect {
        activity.send(
          :validate_create_feature_changed_files!,
          feature_agent_run, client
        )
      }.to raise_error(RuntimeError, /outside allowlist/)
    end

    it "uses the create_feature-specific PR title" do
      activity = Activities::CreatePullRequestActivity.new

      title = activity.send(:create_feature_pr_title, feature_agent_run)
      expect(title).to start_with("docs:")
      expect(title).to include("Add dark mode")
    end

    it "uses the create_feature-specific PR body" do
      activity = Activities::CreatePullRequestActivity.new

      body = activity.send(:build_create_feature_pr_body, feature_agent_run)
      expect(body[:body]).to include("Feature Creation RDR")
      expect(body[:body]).to include("Add dark mode")
    end
  end

  # ---------------------------------------------------------------------------
  # RDR contract validation
  # ---------------------------------------------------------------------------
  describe "RDR contract validation" do
    let(:agent_run) { build_stubbed(:agent_run, goal: "create_feature") }
    let(:rdr_path) { "docs/rdrs/RDR-053-new-feature-creation.md" }
    let(:rdr_body) do
      Features::RdrContract::REQUIRED_SECTIONS.each_with_index.each_with_object(+"") do |(section, _), str|
        str << "## #{section}\n\nbody\n\n"
      end
    end

    it "passes when all required sections and index are present" do
      result = Features::RdrContract.call(
        agent_run: agent_run,
        changed_files: [ rdr_path, "docs/rdrs/README.md" ],
        contents: {
          rdr_path => rdr_body,
          "docs/rdrs/README.md" => "| [RDR-053](RDR-053-new-feature-creation.md) | New | Draft | P1 |"
        }
      )

      expect(result.valid?).to be true
      expect(result.missing).to eq([])
      expect(result.new_rdr_path).to eq(rdr_path)
      expect(result.index_updated).to be true
    end

    it "fails when a required section is missing" do
      incomplete = "# RDR-099: Short\n\n## Metadata\n\n- Date: 2026-08-09\n\n## Problem Statement\n\nBrief.\n"

      result = Features::RdrContract.call(
        agent_run: agent_run,
        changed_files: [ "docs/rdrs/RDR-099-short.md", "docs/rdrs/README.md" ],
        contents: {
          "docs/rdrs/RDR-099-short.md" => incomplete,
          "docs/rdrs/README.md" => "| [RDR-099](RDR-099-short.md) | Short | Draft | P1 |"
        }
      )

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/Context/))
    end

    it "fails when the README index is not in changed files" do
      result = Features::RdrContract.call(
        agent_run: agent_run,
        changed_files: [ rdr_path ],
        contents: { rdr_path => rdr_body }
      )

      expect(result.valid?).to be false
      expect(result.missing).to include(a_string_matching(/index update/))
    end
  end

  # ---------------------------------------------------------------------------
  # Issue tree structure validation
  # ---------------------------------------------------------------------------
  describe "issue tree structure" do
    it "issue dependency parsing supports cross-references via extract" do
      body = <<~BODY
        ## Dependencies

        Depends on #123
        Blocked by org/repo#456
      BODY

      local_deps, cross_deps = Issues::ParseDependencies.extract(body: body, comments: [])

      expect(local_deps).to have_key(123)
      expect(cross_deps.keys).to include([ "org", "repo", 456 ])
    end

    it "instructs the agent to reference the source RDR in filed child issue bodies" do
      prompt = Prompts::BuildForCreateFeature.call(
        project_name: project.name,
        full_name: project.full_name,
        feature_brief: complete_feature_brief
      )

      expect(prompt).to include("Part of RDR-0XX")
    end

    it "create_feature runs can have cross_repo_issues set" do
      agent_run = create(
        :agent_run, :create_feature_goal, project: project,
        external_metadata: { "feature_brief" => complete_feature_brief }
      )

      agent_run.update!(cross_repo_issues: [
        { "number" => 100, "url" => "https://github.com/example/repo/issues/100", "title" => "Epic: Add dark mode" },
        { "number" => 101, "url" => "https://github.com/example/repo/issues/101", "title" => "Phase 1: Toggle" }
      ])

      expect(agent_run.cross_repo_issues.size).to eq(2)
      expect(agent_run.cross_repo_issues.first["title"]).to include("Epic")
    end
  end
end
