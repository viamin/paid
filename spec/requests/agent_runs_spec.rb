# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AgentRuns" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account, created_by: user) }
  let(:project) { create(:project, account: account, github_token: github_token, created_by: user) }

  describe "GET /agent_runs" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get agent_runs_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get agent_runs_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Agent Runs")
      end

      it "shows agent runs across all projects" do
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed")
        get agent_runs_path
        expect(response.body).to include(project.name)
      end

      it "shows each run goal type label in the index table with a mobile tooltip wrapper" do
        run = create(:agent_run, :with_custom_prompt, project: project, goal: "create_pr",
          custom_prompt: "Implement multi-step OAuth token refresh handling for stale sessions")

        get agent_runs_path

        document = parsed_html

        expect(goal_column_index(document)).not_to be_nil

        goal_cell = goal_cell_for_run(document, run)
        tooltip_wrapper = goal_cell.at_css('[data-controller="tooltip"]')
        truncated_label = goal_cell.at_css("span.block.truncate")

        expect(goal_cell.text).to include("PR Creation")
        expect(truncated_label["title"]).to eq("PR Creation")
        expect(tooltip_wrapper).to be_present
        expect(tooltip_wrapper.at_css('button[aria-label="Show goal details"]')).to be_present
        expect(tooltip_wrapper.at_css('span[role="tooltip"]')["id"]).to eq("goal_#{run.id}")
      end

      it "aligns the Runner header with runner values in each row" do
        owner = project.effective_owner
        configured_runner = owner.runners.create!(
          runner_key: "cursor",
          auth_type: "subscription",
          name: "Cursor Stable",
          enabled_for_agent_runs: true
        )
        run = create(:agent_run, :with_custom_prompt, project: project, runner: configured_runner,
          final_runner: configured_runner.routing_key)

        get agent_runs_path

        runner_cell = cell_for_run(parsed_html, run, "Runner")

        expect(runner_cell.text.squish).to eq(configured_runner.display_name)
      end

      it "shows a deleted-runner fallback label in the Runner column" do
        run = create(:agent_run, :with_custom_prompt, project: project, runner: nil,
          final_runner: "runner:999999")

        get agent_runs_path

        runner_cell = cell_for_run(parsed_html, run, "Runner")

        expect(runner_cell.text.squish).to eq(ApplicationHelper::MISSING_RUNNER_ENTRY_LABEL)
      end

      it "shows the deleted-runner fallback label when the final routed runner is missing" do
        initial_runner = project.effective_owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
        run = create(:agent_run, :with_custom_prompt, project: project, runner: initial_runner,
          final_runner: "runner:999999")

        get agent_runs_path

        runner_cell = cell_for_run(parsed_html, run, "Runner")

        expect(runner_cell.text.squish).to eq(ApplicationHelper::MISSING_RUNNER_ENTRY_LABEL)
      end

      it "does not show another owner's routed runner label in the Runner column" do
        other_user = create(:user)
        other_runner = create(:runner, user: other_user, runner_key: "cursor", name: "Other Owner Cursor")
        run = create(:agent_run, :with_custom_prompt, project: project, runner: nil,
          final_runner: other_runner.routing_key)

        get agent_runs_path

        runner_cell = cell_for_run(parsed_html, run, "Runner")

        expect(runner_cell.text.squish).to eq(ApplicationHelper::MISSING_RUNNER_ENTRY_LABEL)
        expect(response.body).not_to include(other_runner.display_name)
      end

      it "normalizes legacy final_runner aliases in the Runner column" do
        run = create(:agent_run, :with_custom_prompt, project: project, runner: nil,
          final_runner: "claude_code", agent_type: "claude_code")

        get agent_runs_path

        runner_cell = cell_for_run(parsed_html, run, "Runner")

        expect(runner_cell.text.squish).to eq(Runner.display_name_for("claude"))
      end

      it "shows distinct goal and context values for create_pr runs" do
        issue = create(:issue, project: project, title: "Fix flaky webhook retry handling")
        run = create(:agent_run, :with_custom_prompt, project: project, issue: issue,
          custom_prompt: "Rendered task instructions that should not appear")

        get agent_runs_path

        document = parsed_html
        goal_cell = goal_cell_for_run(document, run)
        context_cell = cell_for_run(document, run, "Context")

        expect(goal_cell.text).to include("PR Creation")
        expect(goal_cell.text).not_to include(issue.title)
        expect(goal_cell.text).not_to include(run.custom_prompt)
        expect(context_cell.text).to include("Issue ##{issue.github_number}")
      end

      it "shows review goal labels separately from review context" do
        run = create(:agent_run, :review_goal, :with_custom_prompt, project: project, issue: nil,
          custom_prompt: "Generated review instructions that should not appear",
          source_pull_request_number: 87)

        get agent_runs_path

        document = parsed_html
        goal_cell = goal_cell_for_run(document, run)
        context_cell = cell_for_run(document, run, "Context")

        expect(goal_cell.text).to include("Code Review")
        expect(goal_cell.text).not_to include("PR #87")
        expect(goal_cell.text).not_to include(run.custom_prompt)
        expect(context_cell.text).to include("PR #87")
      end

      it "shows custom prompt context separately from the goal label" do
        goal_text = "Investigate the flaky deploy status check"
        run = create(:agent_run, :with_custom_prompt, project: project, goal: "create_pr",
          issue: nil, custom_prompt: goal_text)

        get agent_runs_path

        document = parsed_html
        goal_cell = goal_cell_for_run(document, run)
        context_cell = cell_for_run(document, run, "Context")

        expect(goal_cell.text).to include("PR Creation")
        expect(goal_cell.text).not_to include(goal_text)
        expect(context_cell.text).to include(goal_text)
        expect(context_cell.at_css("span[title]")["title"]).to eq(goal_text)
        expect(context_cell.at_css('[data-controller="tooltip"]')).to be_present
      end

      it "shows a titleized fallback label for unexpected goal values" do
        run = create(:agent_run, :with_custom_prompt, project: project, custom_prompt: "Temporary goal")
        run.update_columns(goal: "some_new_goal")

        get agent_runs_path

        goal_cell = goal_cell_for_run(parsed_html, run)

        expect(goal_cell.text).to include("Some New Goal")
      end

      it "shows the runner column with the resolved runner name" do
        runner = create(:runner, user: user, runner_key: "codex")
        run = create(:agent_run, project: project, runner: runner, final_runner: runner.routing_key)

        get agent_runs_path

        document = parsed_html

        expect(column_index(document, "Runner")).not_to be_nil
        expect(cell_for_run(document, run, "Runner").text.squish).to eq(runner.display_name)
      end

      it "shows a fallback label when the final runner record is missing" do
        run = create(:agent_run, project: project, final_runner: "runner:999999")

        get agent_runs_path

        expect(cell_for_run(parsed_html, run, "Runner").text.squish).to eq("Deleted runner entry")
      end

      it "shows the final runner label for legacy fallback runs" do
        initial_runner = create(:runner, user: user, runner_key: "codex")
        run = create(:agent_run, project: project, runner: initial_runner, final_runner: "cursor")

        get agent_runs_path

        expect(cell_for_run(parsed_html, run, "Runner").text.squish).to eq(Runner.display_name_for("cursor"))
      end

      it "renders unsupported runner identifiers without error" do
        run = create(:agent_run, project: project, runner: nil, final_runner: "api", agent_type: "api")

        get agent_runs_path

        expect(response).to have_http_status(:ok)
        expect(cell_for_run(parsed_html, run, "Runner").text.squish).to eq("Api")
      end

      it "shows empty state when no runs exist" do
        get agent_runs_path
        expect(response.body).to include("No agent runs yet")
      end

      it "filters agent runs using Ransack q params" do
        matching_run = create(:agent_run, :with_git_context, project: project, branch_name: "feature/alpha")
        excluded_run = create(:agent_run, :with_git_context, project: project, branch_name: "fix/beta")

        get agent_runs_path, params: { q: { branch_name_cont: "alpha" } }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(project_agent_run_path(project, matching_run))
        expect(response.body).not_to include(project_agent_run_path(project, excluded_run))
      end

      it "filters agent runs by goal type" do
        pr_run = create(:agent_run, project: project, goal: "create_pr")
        issue_run = create(:agent_run, :with_custom_prompt, project: project, goal: "create_issue")

        get agent_runs_path, params: { q: { goal_eq: "create_pr" } }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(project_agent_run_path(project, pr_run))
        expect(response.body).not_to include(project_agent_run_path(project, issue_run))
      end

      it "shows named runner filter labels and omits unresolved routed ids" do
        kept_runner = create(:runner, user: project.effective_owner, runner_key: "opencode", name: "Kimi K2.5")
        create(:agent_run, project: project, final_runner: kept_runner.routing_key)
        create(:agent_run, project: project, final_runner: "runner:999999")
        kept_runner.discard!

        get agent_runs_path

        option_text = parsed_html.css('select[name="q[effective_runner_eq]"] option').map { |option| option.text.squish }

        expect(option_text).to include("Kimi K2.5")
        expect(option_text).not_to include("runner:999999")
      end

      it "shows the goal filter dropdown" do
        get agent_runs_path

        expect(response.body).to include("All Goals")
      end

      it "associates the sort label with the sort select" do
        get agent_runs_path

        expect(response.body).to match(/<label[^>]*for="sort"[^>]*>Sort<\/label>/)
        expect(response.body).to match(/<select[^>]*name="sort"[^>]*id="sort"[^>]*>/)
      end

      it "sorts agent runs ascending via Ransack sort params" do
        other_project = create(:project, account: account, github_token: github_token, created_by: user)
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed", created_at: 2.days.ago)
        create(:agent_run, project: other_project, agent_type: "claude_code", status: "completed", created_at: 1.day.ago)

        get agent_runs_path, params: { q: { s: "created_at asc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(project.name)).to be < response.body.index(other_project.name)
      end

      it "sorts agent runs descending via Ransack sort params" do
        other_project = create(:project, account: account, github_token: github_token, created_by: user)
        create(:agent_run, project: project, agent_type: "claude_code", status: "completed", created_at: 2.days.ago)
        create(:agent_run, project: other_project, agent_type: "claude_code", status: "completed", created_at: 1.day.ago)

        get agent_runs_path, params: { q: { s: "created_at desc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(other_project.name)).to be < response.body.index(project.name)
      end

      it "shows issue link in context column for create_issue goal runs" do
        create(:agent_run, :with_created_issue, :completed, project: project)
        get agent_runs_path
        expect(response.body).to include("Issue #42")
        expect(response.body).to include("https://github.com/example/repo/issues/42")
      end

      it "shows linked issue in context column for create_pr goal runs" do
        issue = create(:issue, project: project, github_number: 7, title: "Context test")
        create(:agent_run, project: project, issue: issue, goal: "create_pr")
        get agent_runs_path
        expect(response.body).to include("#7")
      end

      it "links to PR in context column for review goal runs" do
        run = create(:agent_run, :review_goal, :completed, project: project)
        get agent_runs_path
        expected_url = "#{project.github_url}/pull/#{run.source_pull_request_number}"
        expect(response.body).to include("PR ##{run.source_pull_request_number}")
        expect(response.body).to include(expected_url)
      end

      it "shows review link in actions column when review_url is present" do
        create(:agent_run, :with_review, project: project)
        get agent_runs_path
        expect(response.body).to include("Review")
        expect(response.body).to include("https://github.com/example/repo/pull/10#pullrequestreview-123456")
      end

      it "shows PR link in actions column for completed create_pr runs" do
        create(:agent_run, :completed, project: project)
        get agent_runs_path
        expect(response.body).to include(">PR</a>")
        expect(response.body).to include("https://github.com/example/repo/pull/1")
      end

      it "does not show runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, :without_creator, account: other_account)
        other_project = create(:project, :without_creator, account: other_account, github_token: other_token)
        create(:agent_run, project: other_project, agent_type: "claude_code", status: "completed")

        get agent_runs_path
        expect(response.body).not_to include(other_project.name)
      end

      it "does not render the navbar pause indicator when the scheduler is running" do
        get agent_runs_path
        expect(response.body).not_to include("navbar-scheduler-paused")
      end

      it "renders the navbar pause indicator (desktop and mobile) when the scheduler is paused" do
        account.update!(scheduler_paused_at: Time.current)
        get agent_runs_path
        expect(response.body).to include("navbar-scheduler-paused")
        expect(response.body).to include("navbar-scheduler-paused-mobile")
      end

      context "when authorized to manage the account" do
        before { user.add_role(:admin, account) }

        it "shows the pause all button when scheduler is running" do
          get agent_runs_path
          expect(response.body).to include("Pause All")
          expect(response.body).to include(pause_scheduler_agent_runs_path)
        end

        it "shows the resume button and paused banner when scheduler is paused" do
          account.update!(scheduler_paused_at: Time.current)
          get agent_runs_path
          expect(response.body).to include("Resume Scheduler")
          expect(response.body).to include("Scheduler paused")
          expect(response.body).to include(resume_scheduler_agent_runs_path)
        end
      end

      context "without permission to manage the account" do
        before { user.add_role(:member, account) }

        it "does not render the pause all button when scheduler is running" do
          get agent_runs_path
          expect(response.body).not_to include("Pause All")
          expect(response.body).not_to include(pause_scheduler_agent_runs_path)
        end

        it "does not render the resume button when scheduler is paused but still shows the banner" do
          account.update!(scheduler_paused_at: Time.current)
          get agent_runs_path
          expect(response.body).not_to include("Resume Scheduler")
          expect(response.body).not_to include(resume_scheduler_agent_runs_path)
          expect(response.body).to include("Scheduler paused")
        end
      end
    end
  end

  describe "POST /agent_runs/pause_scheduler" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post pause_scheduler_agent_runs_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as an admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "marks the current account's scheduler as paused" do
        freeze_time do
          post pause_scheduler_agent_runs_path

          expect(account.reload.scheduler_paused_at).to eq(Time.current)
          expect(response).to redirect_to(agent_runs_path)
          expect(flash[:notice]).to include("paused")
        end
      end

      it "is idempotent when the scheduler is already paused" do
        original_time = 2.hours.ago
        account.update!(scheduler_paused_at: original_time)

        post pause_scheduler_agent_runs_path

        expect(account.reload.scheduler_paused_at).to be_within(1.second).of(original_time)
        expect(response).to redirect_to(agent_runs_path)
      end
    end

    context "when authenticated as a member without admin role" do
      before do
        user.add_role(:member, account)
        sign_in user
      end

      it "rejects the request" do
        post pause_scheduler_agent_runs_path

        expect(account.reload.scheduler_paused_at).to be_nil
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "POST /agent_runs/resume_scheduler" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post resume_scheduler_agent_runs_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as an admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "clears the paused-at timestamp and enqueues the queue processor" do
        account.update!(scheduler_paused_at: 1.hour.ago)

        expect {
          post resume_scheduler_agent_runs_path
        }.to have_enqueued_job(ProcessRunQueueJob)

        expect(account.reload.scheduler_paused_at).to be_nil
        expect(response).to redirect_to(agent_runs_path)
        expect(flash[:notice]).to include("resumed")
      end

      it "is a no-op when the scheduler is not paused" do
        expect {
          post resume_scheduler_agent_runs_path
        }.not_to have_enqueued_job(ProcessRunQueueJob)

        expect(account.reload.scheduler_paused_at).to be_nil
        expect(response).to redirect_to(agent_runs_path)
      end
    end

    context "when authenticated as a member without admin role" do
      before do
        user.add_role(:member, account)
        account.update!(scheduler_paused_at: 1.hour.ago)
        sign_in user
      end

      it "rejects the request" do
        original_time = account.scheduler_paused_at

        post resume_scheduler_agent_runs_path

        expect(account.reload.scheduler_paused_at).to be_within(1.second).of(original_time)
        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "GET /projects/:project_id/agent_runs" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get project_agent_runs_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the index page" do
        get project_agent_runs_path(project)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Agent Runs")
      end

      it "shows agent runs for the project" do
        run = create(:agent_run, project: project, agent_type: "claude_code", status: "completed")
        get project_agent_runs_path(project)
        expect(response.body).to include(project_agent_run_path(project, run))
      end

      it "shows empty state when no runs exist" do
        get project_agent_runs_path(project)
        expect(response.body).to include("No agent runs yet")
      end

      it "filters agent runs using Ransack q params" do
        matching_run = create(:agent_run, :with_git_context, project: project, branch_name: "feature/gamma")
        excluded_run = create(:agent_run, :with_git_context, project: project, branch_name: "fix/delta")

        get project_agent_runs_path(project), params: { q: { branch_name_cont: "gamma" } }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(project_agent_run_path(project, matching_run))
        expect(response.body).not_to include(project_agent_run_path(project, excluded_run))
      end

      it "filters agent runs by goal type" do
        pr_run = create(:agent_run, project: project, goal: "create_pr")
        issue_run = create(:agent_run, :with_custom_prompt, project: project, goal: "create_issue")

        get project_agent_runs_path(project), params: { q: { goal_eq: "create_pr" } }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(project_agent_run_path(project, pr_run))
        expect(response.body).not_to include(project_agent_run_path(project, issue_run))
      end

      it "sorts agent runs via Ransack sort params" do
        older_run = create(:agent_run, project: project, agent_type: "claude_code", status: "completed", created_at: 2.days.ago)
        newer_run = create(:agent_run, project: project, agent_type: "cursor", status: "completed", created_at: 1.day.ago)

        get project_agent_runs_path(project), params: { q: { s: "created_at asc" } }

        expect(response).to have_http_status(:ok)
        expect(response.body.index(project_agent_run_path(project, older_run))).to be < response.body.index(project_agent_run_path(project, newer_run))
      end

      it "shows issue link in context column for create_issue goal runs" do
        create(:agent_run, :with_created_issue, :completed, project: project)
        get project_agent_runs_path(project)
        expect(response.body).to include("Issue #42")
        expect(response.body).to include("https://github.com/example/repo/issues/42")
      end

      it "shows linked issue in context column for create_pr goal runs" do
        issue = create(:issue, project: project, github_number: 7, title: "Context test")
        create(:agent_run, project: project, issue: issue, goal: "create_pr")
        get project_agent_runs_path(project)
        expect(response.body).to include("#7")
      end

      it "links to PR in context column for review goal runs" do
        run = create(:agent_run, :review_goal, :completed, project: project)
        get project_agent_runs_path(project)
        expected_url = "#{project.github_url}/pull/#{run.source_pull_request_number}"
        expect(response.body).to include("PR ##{run.source_pull_request_number}")
        expect(response.body).to include(expected_url)
      end

      it "shows review link in actions column when review_url is present" do
        create(:agent_run, :with_review, project: project)
        get project_agent_runs_path(project)
        expect(response.body).to include("Review")
        expect(response.body).to include("https://github.com/example/repo/pull/10#pullrequestreview-123456")
      end

      it "shows the runner column with the resolved runner name" do
        runner = create(:runner, user: user, runner_key: "cursor")
        run = create(:agent_run, project: project, runner: runner, final_runner: runner.routing_key)

        get project_agent_runs_path(project)

        document = parsed_html

        expect(column_index(document, "Runner")).not_to be_nil
        expect(cell_for_run(document, run, "Runner").text.squish).to eq(runner.display_name)
      end

      it "shows the final runner label for legacy fallback runs" do
        initial_runner = create(:runner, user: user, runner_key: "codex")
        run = create(:agent_run, project: project, runner: initial_runner, final_runner: "cursor")

        get project_agent_runs_path(project)

        expect(cell_for_run(parsed_html, run, "Runner").text.squish).to eq(Runner.display_name_for("cursor"))
      end

      it "renders unsupported runner identifiers without error" do
        run = create(:agent_run, project: project, runner: nil, final_runner: "api", agent_type: "api")

        get project_agent_runs_path(project)

        expect(response).to have_http_status(:ok)
        expect(cell_for_run(parsed_html, run, "Runner").text.squish).to eq("Api")
      end

      it "shows PR link in actions column for completed create_pr runs" do
        create(:agent_run, :completed, project: project)
        get project_agent_runs_path(project)
        expect(response.body).to include(">PR</a>")
        expect(response.body).to include("https://github.com/example/repo/pull/1")
      end

      it "does not show runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, :without_creator, account: other_account)
        other_project = create(:project, :without_creator, account: other_account, github_token: other_token)
        get project_agent_runs_path(other_project)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /projects/:project_id/agent_runs/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        agent_run = create(:agent_run, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "shows agent run details" do
        agent_run = create(:agent_run, project: project, agent_type: "claude_code", status: "running")
        get project_agent_run_path(project, agent_run)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Agent Run ##{agent_run.id}")
        expect(response.body).to include("Claude Code")
      end

      it "masks the auth refresh token input when a browser auth URL is available" do
        agent_run = create(:agent_run, :auth_expired, project: project, auth_provider: "claude")
        without_partial_double_verification do
          allow(AgentHarness).to receive(:respond_to?).and_call_original
          allow(AgentHarness).to receive(:respond_to?).with(:refresh_auth).and_return(true)
          allow(AgentHarness).to receive(:respond_to?).with(:auth_url).and_return(true)
          allow(AgentHarness).to receive(:auth_url).with(:claude).and_return("https://example.com/auth")
        end

        get project_agent_run_path(project, agent_run)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('type="password"')
        expect(response.body).to include('name="auth_token"')
        expect(response.body).to include('autocomplete="off"')
        expect(response.body).to include('spellcheck="false"')
      end

      it "shows auth-expired details when the runner cannot generate an auth URL" do
        agent_run = create(:agent_run, :auth_expired, project: project, agent_type: "codex", auth_provider: "codex")
        without_partial_double_verification do
          allow(AgentHarness).to receive(:respond_to?).and_call_original
          allow(AgentHarness).to receive(:respond_to?).with(:refresh_auth).and_return(true)
          allow(AgentHarness).to receive(:respond_to?).with(:auth_url).and_return(true)
          allow(AgentHarness).to receive(:auth_url)
            .with(:codex)
            .and_raise(NotImplementedError, "Runner codex uses api_key auth and does not support OAuth URL generation")
        end

        get project_agent_run_path(project, agent_run)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Paid cannot generate a browser login URL")
        expect(response.body).to include("Codex")
      end

      it "shows the run timeline when phase data exists" do
        agent_run = create(:agent_run, :completed, project: project)
        create(:agent_run_phase, agent_run: agent_run, phase_key: "prepare_pr_prompt", phase_group: "prompt")
        create(:agent_run_phase, agent_run: agent_run, phase_key: "run_agent", phase_group: "agent")

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include("Run Timeline")
        expect(response.body).to include("Run Agent")
        expect(response.body).to include("Prepare PR Prompt")
      end

      it "shows the empty timeline state when no phase data exists" do
        agent_run = create(:agent_run, :completed, project: project)

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include("Run Timeline")
        expect(response.body).to include("Phase timing will appear here once this run records lifecycle events.")
        expect(response.body).not_to include("Run Agent")
      end

      it "shows issue details when attached" do
        issue = create(:issue, project: project, github_number: 42, title: "Fix the bug")
        agent_run = create(:agent_run, project: project, issue: issue)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("#42")
        expect(response.body).to include("Fix the bug")
      end

      it "shows PR link when available" do
        agent_run = create(:agent_run, :completed, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Pull Request Created")
        expect(response.body).to include(agent_run.pull_request_url)
      end

      it "shows review link when available" do
        agent_run = create(:agent_run, :with_review, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Review Posted")
        expect(response.body).to include(agent_run.review_url)
      end

      it "shows error message when run failed" do
        agent_run = create(:agent_run, :failed, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Error")
        expect(response.body).to include(agent_run.error_message)
      end

      it "shows retry runner options for configured providers" do
        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])
        project.effective_owner.runners.create!(runner_key: "cursor")
        agent_run = create(:agent_run, :failed, project: project, agent_type: "claude_code")

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include("Retry with Anthropic Claude CLI")
        expect(response.body).to include("Retry with Cursor AI")
        expect(response.body).to include("Current")
        expect(response.body).to include('aria-haspopup="menu"')
        expect(response.body).to include("aria-controls=")
        expect(response.body).to include("aria-labelledby=")
      end

      it "marks only one retry option current for legacy runs without runner_id" do
        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude opencode])
        owner = project.effective_owner
        api_key = create(:runner_api_key, user: owner, api_service_type: "openrouter")
        create_opencode_runner_entry(user: owner, api_key: api_key, name: "Kimi K2.5", model: "moonshotai/kimi-k2-0905")
        create_opencode_runner_entry(user: owner, api_key: api_key, name: "Opus via OpenCode", model: "anthropic/claude-opus-4.1")
        agent_run = create(:agent_run, :failed, project: project, agent_type: "opencode", runner: nil)

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include("Retry with Kimi K2.5")
        expect(response.body).to include("Retry with Opus via OpenCode")
        expect(response.body.scan("Current").size).to eq(1)
      end

      it "shows a single retry button when no alternate providers are configured" do
        agent_run = create(:agent_run, :failed, project: project, agent_type: "claude_code")

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include(">Retry</button>")
        expect(response.body).not_to include("Retry options")
        expect(response.body).not_to include('role="menu"')
      end

      it "shows a deleted runner entry label for missing routed fallback attempts" do
        agent_run = create(
          :agent_run,
          :failed,
          project: project,
          final_runner: "runner:999999",
          runner_switches: 1,
          runners_attempted: [
            { "runner" => "runner:999999", "success" => false, "error_type" => "rate_limited" }
          ]
        )

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include(ApplicationHelper::MISSING_RUNNER_ENTRY_LABEL)
        expect(response.body).not_to include("Runner:999999")
      end

      it "normalizes legacy final_runner aliases in the header runner label" do
        agent_run = create(:agent_run, :completed, project: project, runner: nil,
          agent_type: "claude_code", final_runner: "claude_code")

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include(Runner.display_name_for("claude"))
        expect(response.body).not_to include(">Claude Code<")
      end

      it "shows metrics" do
        agent_run = create(:agent_run, :completed, :with_metrics, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Iterations")
        expect(response.body).to include("Duration")
        expect(response.body).to include("Tokens")
        expect(response.body).to include("Cost")
      end

      it "shows runner section with active runner name" do
        owner = project.effective_owner
        runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
        agent_run = create(:agent_run, :running, project: project, agent_type: "claude_code", runner: runner)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Active Runner")
        expect(response.body).to include(runner.display_name)
      end

      it "shows fallback badge and originally requested runner when fallback occurred" do
        owner = project.effective_owner
        initial_runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
        fallback_runner = owner.runners.create!(runner_key: "cursor", auth_type: "subscription")
        agent_run = create(
          :agent_run,
          :completed,
          project: project,
          agent_type: "claude_code",
          runner: initial_runner,
          final_runner: fallback_runner.routing_key,
          runner_switches: 1,
          runners_attempted: [
            { "runner" => initial_runner.routing_key, "success" => false, "error_type" => "rate_limited" },
            { "runner" => fallback_runner.routing_key, "success" => true }
          ]
        )
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Fallback")
        expect(response.body).to include("Originally Requested")
        expect(response.body).to include("Runner Switches")
      end

      it "shows runner attempt error details in the fallback panel" do
        owner = project.effective_owner
        initial_runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
        fallback_runner = create_opencode_fallback_runner(user: owner, name: "Kimi K2", model: "moonshotai/kimi-k2-0905")
        agent_run = create(
          :agent_run,
          :failed,
          project: project,
          agent_type: "claude_code",
          runner: initial_runner,
          runner_switches: 1,
          runners_attempted: [
            runner_attempt(initial_runner.routing_key, "rate_limited", "Skipped due to cached rate limit until 2026-04-30T05:59:15Z"),
            runner_attempt(fallback_runner.routing_key, "error", "Configuration is invalid at /home/agent/.config/opencode/opencode.json")
          ]
        )

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include("Skipped due to cached rate limit until 2026-04-30T05:59:15Z")
        expect(response.body).to include("Configuration is invalid at /home/agent/.config/opencode/opencode.json")
      end

      it "shows runner attempts even when no fallback switch occurred" do
        owner = project.effective_owner
        initial_runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
        agent_run = create(
          :agent_run,
          :failed,
          project: project,
          agent_type: "claude_code",
          runner: initial_runner,
          runner_switches: 0,
          runners_attempted: [
            runner_attempt(initial_runner.routing_key, "rate_limited", "Skipped due to cached rate limit until 2026-04-30T05:59:15Z")
          ]
        )

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include("Runner Attempts")
        expect(response.body).to include("1 attempt")
        expect(response.body).to include(initial_runner.display_name)
        expect(response.body).to include("Skipped due to cached rate limit until 2026-04-30T05:59:15Z")
        expect(response.body).not_to include(ApplicationHelper::MISSING_RUNNER_ENTRY_LABEL)
      end

      it "shows auth type in runner section when runner record exists" do
        owner = project.effective_owner
        runner = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
        agent_run = create(:agent_run, :completed, project: project, runner: runner)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("Auth Type")
        expect(response.body).to include("Subscription")
      end

      it "shows quality scores when quality metrics exist" do
        agent_run = create(:agent_run, :completed, project: project)
        create(:quality_metric, agent_run: agent_run, composite_score: 0.85)

        get project_agent_run_path(project, agent_run)

        expect(response.body).to include("Quality Scores")
        expect(response.body).to include("85.0%")
      end

      it "does not show quality scores when no quality metrics exist" do
        agent_run = create(:agent_run, :completed, project: project)

        get project_agent_run_path(project, agent_run)

        expect(response.body).not_to include("Quality Scores")
      end

      it "shows git details when available" do
        agent_run = create(:agent_run, :with_git_context, project: project)
        get project_agent_run_path(project, agent_run)
        expect(response.body).to include("agent/feature-implementation")
      end

      it "does not show runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, :without_creator, account: other_account)
        other_project = create(:project, :without_creator, account: other_account, github_token: other_token)
        other_run = create(:agent_run, project: other_project)
        get project_agent_run_path(other_project, other_run)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /projects/:project_id/agent_runs/new" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get new_project_agent_run_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "renders the trigger form" do
        get new_project_agent_run_path(project)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Trigger Agent Run")
        expect(response.body).to include("Claude")
      end

      it "includes goal-toggle Stimulus wiring" do
        create(:issue, :pull_request, project: project, github_number: 20, title: "Wiring PR")
        get new_project_agent_run_path(project)
        body = response.body
        expect(body).to include('data-controller="goal-toggle"')
        expect(body).to include('data-action="change->goal-toggle#toggle"')
        expect(body).to include('data-goal-toggle-target="issueSection"')
        expect(body).to include('data-goal-toggle-target="prSection"')
        expect(body).to include('data-goal-toggle-target="prTable"')

        doc = Nokogiri::HTML(body)
        pr_table = doc.at_css('[data-goal-toggle-target="prTable"]')
        expect(pr_table).not_to be_nil
        expect(pr_table["class"].to_s).not_to include("hidden")
      end

      it "shows all open issues in dropdown regardless of paid_state" do
        create(:issue, project: project, github_number: 10, title: "Open issue", github_state: "open", paid_state: "new")
        create(:issue, project: project, github_number: 11, title: "Closed issue", github_state: "closed", paid_state: "new")
        create(:issue, project: project, github_number: 12, title: "In progress issue", github_state: "open", paid_state: "in_progress")
        get new_project_agent_run_path(project)
        expect(response.body).to include("Open issue")
        expect(response.body).not_to include("Closed issue")
        expect(response.body).to include("In progress issue")
      end

      it "shows message when no issues available" do
        get new_project_agent_run_path(project)
        expect(response.body).to include("No actionable open issues found")
      end

      it "shows open PRs in dropdown" do
        create(:issue, :pull_request, project: project, github_number: 20, title: "Open PR")
        create(:issue, :pull_request, :closed, project: project, github_number: 21, title: "Closed PR")
        get new_project_agent_run_path(project)
        expect(response.body).to include("Open PR")
        expect(response.body).not_to include("Closed PR")
      end

      it "shows message when no PRs available" do
        get new_project_agent_run_path(project)
        expect(response.body).to include("No open pull requests found")
      end

      it "pre-selects issue when issue_id param is present" do
        issue = create(:issue, project: project, github_number: 10, title: "Preselected issue", github_state: "open", paid_state: "new")
        get new_project_agent_run_path(project, issue_id: issue.id)
        expect(response.body).to include("selected")
        expect(response.body).to include("Preselected issue")
      end

      it "disables issues with an open paid-generated PR in the dropdown" do
        issue = create(:issue, project: project, github_number: 10, title: "Has paid PR", github_state: "open", paid_state: "new")
        pr = create(:issue, :pull_request, project: project, github_number: 77,
          github_state: "open", parent_issue: issue)
        create(:agent_run, :completed, project: project, issue: issue,
          pull_request_number: pr.github_number,
          pull_request_url: "https://github.com/example/repo/pull/#{pr.github_number}")

        get new_project_agent_run_path(project)

        doc = Nokogiri::HTML(response.body)
        option = doc.at_css("select#issue_id option[value='#{issue.id}']")
        expect(option).to be_present
        expect(option["disabled"]).to eq("disabled")
        expect(option.text).to include("open paid PR")
      end

      it "pre-selects PR when pull_request_id param is present" do
        pr = create(:issue, :pull_request, project: project, github_number: 30, title: "Preselected PR")
        get new_project_agent_run_path(project, pull_request_id: pr.id)
        expect(response.body).to include("selected")
        expect(response.body).to include("Preselected PR")
      end

      it "exposes goal-specific runner defaults to the goal toggle controller" do
        owner = project.created_by
        codex = owner.runners.create!(
          runner_key: "codex",
          auth_type: "subscription",
          enabled_for_agent_runs: true,
          enabled_for_fallback: true
        )
        owner.settings.update!(default_agent_runners_by_goal: { "review" => codex.routing_key })

        get new_project_agent_run_path(project)

        doc = Nokogiri::HTML(response.body)
        form = doc.at_css("form[data-controller='goal-toggle']")
        defaults = JSON.parse(form["data-goal-toggle-runner-defaults-value"])
        runner = form.at_css("#runner")

        expect(defaults["create_pr"]).to eq(owner.settings.default_runner_identifier_for_goal("create_pr"))
        expect(defaults["review"]).to eq(codex.routing_key)
        expect(runner["data-goal-toggle-target"]).to eq("runnerSelect")
        expect(runner["data-action"]).to include("change->goal-toggle#runnerChanged")
      end

      it "defaults to Inherit in the runner dropdown" do
        owner = project.created_by
        codex = owner.runners.create!(
          runner_key: "codex",
          auth_type: "subscription",
          enabled_for_agent_runs: true,
          enabled_for_fallback: true
        )
        owner.settings.update!(default_agent_runners_by_goal: { "review" => codex.routing_key })

        get new_project_agent_run_path(project, goal: "review")

        doc = Nokogiri::HTML(response.body)
        runner_select = doc.at_css("#runner")
        selected_option = runner_select.at_css("option[selected]")

        expect(selected_option["value"]).to eq("")
        expect(selected_option.text.strip).to eq("Inherit (from runner settings)")
      end

      it "renders enhance_issue as a selectable goal with the issue picker active" do
        issue = create(:issue, project: project, github_number: 44, title: "Needs context", github_state: "open")
        create(:issue, :pull_request, project: project, github_number: 45, title: "Open PR")

        get new_project_agent_run_path(project, goal: "enhance_issue")

        doc = Nokogiri::HTML(response.body)
        enhance_goal = doc.at_css("input[type='radio'][name='goal'][value='enhance_issue']")
        issue_table = doc.at_css('[data-goal-toggle-target="issueTable"]')
        issue_dropdown = doc.at_css('[data-goal-toggle-target="issueDropdown"]')
        pr_section = doc.at_css('[data-goal-toggle-target="prSection"]')

        expect(enhance_goal).to be_present
        expect(enhance_goal["checked"]).to eq("checked")
        expect(issue_table["hidden"]).to be_nil
        expect(issue_table.text).to include("Needs context")
        expect(issue_table.at_css("input[type='checkbox'][name='issue_ids[]'][value='#{issue.id}']")).to be_present
        expect(issue_dropdown.attribute("hidden")).to be_present
        expect(pr_section.attribute("hidden")).to be_present
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post project_agent_runs_path(project), params: { issue_id: 1 }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:issue) { create(:issue, project: project, github_number: 42, title: "Fix the bug") }

      before do
        sign_in user
      end

      it "creates a queued run and redirects with success message" do
        post project_agent_runs_path(project), params: { issue_id: issue.id }
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Agent run")
      end

      it "creates an agent run with correct parameters" do
        expect {
          post project_agent_runs_path(project), params: { issue_id: issue.id, agent_type: "claude_code" }
        }.to change(AgentRun, :count).by(1)

        agent_run = AgentRun.last
        expect(agent_run.project).to eq(project)
        expect(agent_run.issue).to eq(issue)
        expect(agent_run.agent_type).to eq("claude_code")
        expect(agent_run.status).to eq("queued")
      end

      it "enqueues ProcessRunQueueJob" do
        expect {
          post project_agent_runs_path(project), params: { issue_id: issue.id }
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "persists the selected priority tier and syncs the issue label" do
        github_client = instance_double(GithubClient, remove_label_from_issue: true, add_labels_to_issue: true)
        allow(GithubClient).to receive(:new).and_return(github_client)
        issue.update!(labels: [ "bug", "P3" ])

        expect {
          post project_agent_runs_path(project), params: { issue_id: issue.id, priority_tier: "P1" }
        }.to change(AgentRun, :count).by(1)

        expect(AgentRun.last.priority_tier).to eq("P1")
        expect(issue.reload.labels).to contain_exactly("bug", "P1")
        expect(github_client).to have_received(:remove_label_from_issue).with(project.full_name, issue.github_number, "P3")
        expect(github_client).to have_received(:add_labels_to_issue).with(project.full_name, issue.github_number, [ "P1" ])
      end

      it "rolls back the agent run when the local issue label update fails" do
        expect(GithubClient).not_to receive(:new)
        issue.update_column(:paid_state, "bogus")

        expect {
          post project_agent_runs_path(project), params: { issue_id: issue.id, priority_tier: "P1" }
        }.not_to change(AgentRun, :count)

        expect(issue.reload.labels).to be_blank
        expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
      end

      it "redirects with error when no issue selected" do
        post project_agent_runs_path(project)
        expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
        follow_redirect!
        expect(response.body).to include("Please select an issue")
      end

      it "rejects a create_pr run when the issue already has an open paid-generated PR" do
        pr_issue = create(:issue, project: project, github_number: 42, title: "Has paid PR")
        pr = create(:issue, :pull_request, project: project, github_number: 99,
          github_state: "open", parent_issue: pr_issue)
        create(:agent_run, :completed, project: project, issue: pr_issue,
          pull_request_number: pr.github_number,
          pull_request_url: "https://github.com/example/repo/pull/#{pr.github_number}")

        expect {
          post project_agent_runs_path(project),
            params: { goal: "create_pr", issue_id: pr_issue.id }
        }.not_to change(AgentRun, :count)

        expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
        follow_redirect!
        expect(response.body).to include("Paid already opened PR ##{pr.github_number}")
      end

      context "with pull_request_id parameter" do
        let(:pr) { create(:issue, :pull_request, project: project, github_number: 77, title: "Fix styles") }

        it "creates a queued run with source_pull_request_number from dropdown" do
          expect {
            post project_agent_runs_path(project), params: { pull_request_id: pr.id }
          }.to change(AgentRun, :count).by(1)

          agent_run = AgentRun.last
          expect(agent_run.source_pull_request_number).to eq(77)
          expect(agent_run.status).to eq("queued")
          expect(response).to redirect_to(project_path(project))
        end

        it "enqueues ProcessRunQueueJob for PR runs" do
          expect {
            post project_agent_runs_path(project), params: { pull_request_id: pr.id }
          }.to have_enqueued_job(ProcessRunQueueJob)
        end
      end

      context "when at capacity" do
        before do
          allow(AgentRun).to receive(:has_run_capacity?).and_return(false)
        end

        it "creates a queued agent run" do
          expect {
            post project_agent_runs_path(project), params: { issue_id: issue.id }
          }.to change(AgentRun, :count).by(1)

          expect(AgentRun.last.status).to eq("queued")
          expect(AgentRun.last.issue).to eq(issue)
        end

        it "redirects with queued notice" do
          post project_agent_runs_path(project), params: { issue_id: issue.id }

          expect(response).to redirect_to(project_path(project))
          follow_redirect!
          expect(response.body).to include("queued")
        end

        it "queues runs with custom prompt" do
          post project_agent_runs_path(project), params: {
            custom_prompt: "Fix the bug"
          }

          expect(AgentRun.last.status).to eq("queued")
          expect(AgentRun.last.custom_prompt).to eq("Fix the bug")
        end

        it "rejects duplicate queued run for the same issue via DB constraint" do
          create(:agent_run, :queued, project: project, issue: issue)

          post project_agent_runs_path(project), params: { issue_id: issue.id }

          expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
          follow_redirect!
          expect(response.body).to include("already queued or in progress")
        end
      end

      it "defaults to the configured runner" do
        post project_agent_runs_path(project), params: { issue_id: issue.id }

        expect(AgentRun.last.agent_type).to eq("claude_code")
      end

      it "ignores invalid agent types and defaults to configured runner" do
        post project_agent_runs_path(project), params: { issue_id: issue.id, agent_type: "invalid" }

        expect(AgentRun.last.agent_type).to eq("claude_code")
      end

      it "falls back when a managed runner is requested but not enabled for the user" do
        post project_agent_runs_path(project), params: { issue_id: issue.id, agent_type: "cursor" }

        expect(AgentRun.last.agent_type).to eq("claude_code")
      end

      it "uses the project owner's runner selection when the signed-in user is not the owner" do
        owner = project.created_by
        owner_cursor = owner.runners.create!(
          runner_key: "cursor",
          auth_type: "subscription",
          enabled_for_agent_runs: true,
          enabled_for_fallback: true
        )
        owner.settings.update!(default_agent_runner: owner_cursor.routing_key)

        post project_agent_runs_path(project), params: { issue_id: issue.id }

        expect(AgentRun.last.runner).to eq(owner_cursor)
        expect(AgentRun.last.agent_type).to eq("cursor")
      end

      it "redirects with an error when no runnable runner can be resolved" do
        owner = project.effective_owner
        allow(UserSetting).to receive(:enabled_agent_runners).with(owner, identifiers: true).and_return([])
        allow(owner.settings).to receive(:runner_priority).with(identifiers: true).and_return([])
        allow(Runner).to receive(:for_identifier).and_return(nil)
        allow(Runner).to receive(:ensure_default_for).with(owner).and_return(nil)

        expect {
          post project_agent_runs_path(project), params: { issue_id: issue.id }
        }.not_to change(AgentRun, :count)

        expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
        follow_redirect!
        expect(response.body).to include("No runnable runner could be resolved for this project")
      end

      context "when budget blocks run creation" do
        let(:issue) { create(:issue, project: project, github_number: 42, title: "Fix the bug") }

        before do
          create(:cost_budget, :hard_stop, :daily, project: project,
            limit_cents: 100, current_usage_cents: 200,
            period_started_at: Time.current.beginning_of_day)
        end

        it "does not create an agent run" do
          expect {
            post project_agent_runs_path(project), params: { issue_id: issue.id }
          }.not_to change(AgentRun, :count)
        end

        it "redirects with a user-friendly budget alert" do
          post project_agent_runs_path(project), params: { issue_id: issue.id }

          expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
          expect(flash[:alert]).to include("budget has been reached")
        end
      end

      it "normalizes an invalid goal to create_pr and uses the create_pr default runner" do
        owner = project.created_by
        codex = owner.runners.create!(
          runner_key: "codex",
          auth_type: "subscription",
          enabled_for_agent_runs: true,
          enabled_for_fallback: true
        )
        owner.settings.update!(default_agent_runners_by_goal: { "create_pr" => codex.routing_key })

        post project_agent_runs_path(project), params: { goal: "invalid", issue_id: issue.id }

        agent_run = AgentRun.last
        expect(agent_run.goal).to eq("create_pr")
        expect(agent_run.runner).to eq(codex)
      end

      context "with goal=review" do
        let(:pr) { create(:issue, :pull_request, project: project, github_number: 55, title: "Review target PR") }

        it "uses the goal-specific default runner when no runner is selected" do
          owner = project.created_by
          codex = owner.runners.create!(
            runner_key: "codex",
            auth_type: "subscription",
            enabled_for_agent_runs: true,
            enabled_for_fallback: true
          )
          owner.settings.update!(default_agent_runners_by_goal: { "review" => codex.routing_key })

          post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ pr.id ] }

          expect(AgentRun.last.runner).to eq(codex)
          expect(AgentRun.last.agent_type).to eq("codex")
        end

        it "creates a review agent run with source_pull_request_number" do
          expect {
            post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ pr.id ] }
          }.to change(AgentRun, :count).by(1)

          agent_run = AgentRun.last
          expect(agent_run.goal).to eq("review")
          expect(agent_run.source_pull_request_number).to eq(55)
          expect(agent_run.status).to eq("queued")
          expect(response).to redirect_to(project_path(project))
        end

        it "redirects with error when no pull request selected" do
          post project_agent_runs_path(project), params: { goal: "review" }

          expect(response).to redirect_to(new_project_agent_run_path(project, goal: "review"))
          follow_redirect!
          expect(response.body).to include("Please select at least one pull request to review")
        end

        it "enqueues ProcessRunQueueJob for review runs" do
          expect {
            post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ pr.id ] }
          }.to have_enqueued_job(ProcessRunQueueJob)
        end

        it "creates one agent run per selected PR when multiple are selected" do
          pr2 = create(:issue, :pull_request, project: project, github_number: 56, title: "Second PR")

          expect {
            post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ pr.id, pr2.id ] }
          }.to change(AgentRun, :count).by(2)

          pr_numbers = AgentRun.last(2).map(&:source_pull_request_number)
          expect(pr_numbers).to contain_exactly(55, 56)
          expect(response).to redirect_to(project_path(project))
          expect(flash[:notice]).to include("2 agent runs queued")
        end

        it "redirects with error when all PR IDs are invalid" do
          post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ 999_999_999 ] }

          expect(response).to redirect_to(new_project_agent_run_path(project, goal: "review"))
          expect(flash[:alert]).to include("None of the selected pull requests could be found")
        end

        it "redirects with error when pull_request_ids param is an empty array" do
          post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [] }

          expect(response).to redirect_to(new_project_agent_run_path(project, goal: "review"))
          expect(flash[:alert]).to include("Please select at least one pull request to review.")
        end

        it "rejects negative and zero PR IDs" do
          post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ "-1", "0" ] }

          expect(response).to redirect_to(new_project_agent_run_path(project, goal: "review"))
          expect(flash[:alert]).to include("Please select at least one pull request to review.")
        end

        it "filters out non-numeric PR IDs" do
          post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ "abc", "", pr.id.to_s ] }

          expect(AgentRun.count).to eq(1)
          expect(AgentRun.last.source_pull_request_number).to eq(55)
        end

        it "filters out PRs with active runs server-side and creates runs for the rest" do
          pr2 = create(:issue, :pull_request, project: project, github_number: 56, title: "Second PR")
          create(:agent_run, :queued, project: project, issue: nil,
            source_pull_request_number: pr.github_number, goal: "review")

          expect {
            post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ pr.id, pr2.id ] }
          }.to change(AgentRun, :count).by(1)

          expect(AgentRun.last.source_pull_request_number).to eq(56)
          expect(response).to redirect_to(project_path(project))
        end

        it "redirects with error when all selected PRs have active runs" do
          create(:agent_run, :queued, project: project, issue: nil,
            source_pull_request_number: pr.github_number, goal: "review")

          expect {
            post project_agent_runs_path(project), params: { goal: "review", pull_request_ids: [ pr.id ] }
          }.not_to change(AgentRun, :count)

          expect(response).to redirect_to(new_project_agent_run_path(project, goal: "review"))
          expect(flash[:alert]).to include("already have active runs")
        end
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/quick_create" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post quick_create_project_agent_runs_path(project), params: { issue_id: 1 }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:issue) { create(:issue, project: project, github_number: 42, title: "Fix the bug") }

      before { sign_in user }

      it "creates a queued run with configured defaults and redirects" do
        expect {
          post quick_create_project_agent_runs_path(project), params: { issue_id: issue.id }
        }.to change(AgentRun, :count).by(1)

        agent_run = AgentRun.last
        expect(agent_run.project).to eq(project)
        expect(agent_run.issue).to eq(issue)
        expect(agent_run.agent_type).to eq("claude_code")
        expect(agent_run.goal).to eq("create_pr")
        expect(agent_run.status).to eq("queued")
        expect(agent_run.custom_prompt).to be_nil
        expect(response).to redirect_to(project_path(project))
      end

      it "enqueues ProcessRunQueueJob" do
        expect {
          post quick_create_project_agent_runs_path(project), params: { issue_id: issue.id }
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "redirects with error when no issue or pull request selected" do
        post quick_create_project_agent_runs_path(project)
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Please select an issue or pull request")
      end

      context "with pull_request_id parameter" do
        let(:pr) { create(:issue, :pull_request, project: project, github_number: 77, title: "Fix styles") }

        it "creates a queued run with source_pull_request_number" do
          expect {
            post quick_create_project_agent_runs_path(project), params: { pull_request_id: pr.id }
          }.to change(AgentRun, :count).by(1)

          agent_run = AgentRun.last
          expect(agent_run.source_pull_request_number).to eq(77)
          expect(agent_run.agent_type).to eq("claude_code")
          expect(agent_run.goal).to eq("create_pr")
          expect(agent_run.status).to eq("queued")
          expect(response).to redirect_to(project_path(project))
        end
      end

      it "rejects quick run for an issue with an open paid-generated pull request" do
        pr_issue = create(:issue, project: project, github_number: 42, title: "Fix the bug")
        pr = create(:issue, :pull_request, project: project, github_number: 99,
          github_state: "open", parent_issue: pr_issue)
        create(:agent_run, :completed, project: project, issue: pr_issue,
          pull_request_number: pr.github_number,
          pull_request_url: "https://github.com/example/repo/pull/#{pr.github_number}")

        expect {
          post quick_create_project_agent_runs_path(project), params: { issue_id: pr_issue.id }
        }.not_to change(AgentRun, :count)

        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Paid already opened PR ##{pr.github_number}")
      end

      it "allows quick run when the associated pull request was not paid-generated" do
        pr_issue = create(:issue, project: project, github_number: 42, title: "Fix the bug")
        create(:issue, :pull_request, project: project, github_number: 100,
          github_state: "open", parent_issue: pr_issue)

        expect {
          post quick_create_project_agent_runs_path(project), params: { issue_id: pr_issue.id }
        }.to change(AgentRun, :count).by(1)
      end

      it "re-enables quick run once the paid-generated pull request is closed" do
        pr_issue = create(:issue, project: project, github_number: 42, title: "Fix the bug")
        pr = create(:issue, :pull_request, :closed, project: project, github_number: 99,
          parent_issue: pr_issue)
        create(:agent_run, :completed, project: project, issue: pr_issue,
          pull_request_number: pr.github_number,
          pull_request_url: "https://github.com/example/repo/pull/#{pr.github_number}")

        expect {
          post quick_create_project_agent_runs_path(project), params: { issue_id: pr_issue.id }
        }.to change(AgentRun, :count).by(1)
      end

      it "ignores goal params and still uses quick-run defaults" do
        expect {
          post quick_create_project_agent_runs_path(project), params: {
            issue_id: issue.id,
            agent_type: "different_agent",
            goal: "different_goal"
          }
        }.to change(AgentRun, :count).by(1)

        agent_run = AgentRun.last
        expect(agent_run.project).to eq(project)
        expect(agent_run.issue).to eq(issue)
        expect(agent_run.agent_type).to eq("claude_code")
        expect(agent_run.goal).to eq("create_pr")
        expect(agent_run.status).to eq("queued")
      end

      it "handles duplicate queued run via DB constraint" do
        create(:agent_run, :queued, project: project, issue: issue)

        post quick_create_project_agent_runs_path(project), params: { issue_id: issue.id }

        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("already queued or in progress")
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/bump_priority" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post bump_priority_project_agent_runs_path(project), params: { pull_request_id: 1 }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:pr) { create(:issue, :pull_request, project: project, github_number: 77, title: "Fix styles") }

      before { sign_in user }

      it "bumps queued auto-continue runs to manual trigger_type and updates updated_at" do
        run = create(:agent_run, :queued, :automatic, project: project,
          source_pull_request_number: 77, custom_prompt: "Fix PR")
        original_updated_at = run.updated_at

        post bump_priority_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        run.reload
        expect(run.trigger_type).to eq("manual")
        expect(run.updated_at).to be > original_updated_at
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Priority bumped")
      end

      it "enqueues ProcessRunQueueJob" do
        create(:agent_run, :queued, :automatic, project: project,
          source_pull_request_number: 77, custom_prompt: "Fix PR")

        expect {
          post bump_priority_project_agent_runs_path(project), params: { pull_request_id: pr.id }
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "bumps queued auto-continue runs only for the selected pull request" do
        _pr2 = create(:issue, :pull_request, project: project, github_number: 78, title: "Other PR")
        run1 = create(:agent_run, :queued, :automatic, project: project,
          source_pull_request_number: 77, custom_prompt: "Fix PR 1")
        run2 = create(:agent_run, :queued, :automatic, project: project,
          source_pull_request_number: 78, custom_prompt: "Fix PR 2")

        post bump_priority_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        expect(run1.reload.trigger_type).to eq("manual")
        expect(run2.reload.trigger_type).to eq("automatic")
      end

      it "redirects with error when no pull request selected" do
        post bump_priority_project_agent_runs_path(project)
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Please select a pull request")
      end

      it "redirects with error when pull_request_id is invalid" do
        post bump_priority_project_agent_runs_path(project), params: { pull_request_id: 999_999 }
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("Please select a pull request")
      end

      it "redirects with error when no queued auto-continue runs exist" do
        create(:agent_run, :completed, :automatic, project: project,
          source_pull_request_number: 77, custom_prompt: "Fix PR")

        post bump_priority_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("No queued auto-continue runs")
      end

      it "does not affect manual runs" do
        manual_run = create(:agent_run, :queued, :manual, project: project,
          source_pull_request_number: 77, custom_prompt: "Manual fix")

        post bump_priority_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        expect(manual_run.reload.trigger_type).to eq("manual")
        expect(response).to redirect_to(project_path(project))
        follow_redirect!
        expect(response.body).to include("No queued auto-continue runs")
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/toggle_auto_continue_pause" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: 1 }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:pr) { create(:issue, :pull_request, project: project, github_number: 77, title: "Fix styles") }

      before { sign_in user }

      it "pauses auto-continue for a PR" do
        expect(pr.auto_continue_paused).to be false

        post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        expect(pr.reload.auto_continue_paused).to be true
        expect(response).to redirect_to(project_path(project))
        expect(flash[:notice]).to include("paused")
      end

      it "resumes auto-continue for a paused PR" do
        pr.update!(auto_continue_paused: true)

        post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        expect(pr.reload.auto_continue_paused).to be false
        expect(response).to redirect_to(project_path(project))
        expect(flash[:notice]).to include("resumed")
      end

      it "enqueues an agent run when resuming" do
        pr.update!(auto_continue_paused: true)

        expect {
          post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }
        }.to change(AgentRun, :count).by(1)

        run = AgentRun.last
        expect(run.source_pull_request_number).to eq(pr.github_number)
        expect(run.status).to eq("queued")
        expect(run.goal).to eq("create_pr")
        expect(run.trigger_type).to eq("automatic")
      end

      it "enqueues ProcessRunQueueJob when resuming" do
        pr.update!(auto_continue_paused: true)

        expect {
          post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "does not enqueue an agent run when resuming if no providers are available" do
        pr.update!(auto_continue_paused: true)

        allow(AgentRun).to receive(:create!)
          .and_raise(Projects::AgentRunsController::NoRunnableProviderError, "No runnable runner")

        expect {
          expect {
            post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }
          }.not_to change(AgentRun, :count)
        }.not_to have_enqueued_job(ProcessRunQueueJob)

        expect(pr.reload.auto_continue_paused).to be false
        expect(flash[:notice]).to include("runner")
      end

      it "does not enqueue an agent run when resuming if an active run already exists" do
        pr.update!(auto_continue_paused: true)

        constraint_error = ActiveRecord::RecordNotUnique.new("idx_agent_runs_unique_active_pr")
        allow(AgentRun).to receive(:create!).and_raise(constraint_error)

        expect {
          expect {
            post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }
          }.not_to change(AgentRun, :count)
        }.not_to have_enqueued_job(ProcessRunQueueJob)

        expect(pr.reload.auto_continue_paused).to be false
        expect(flash[:notice]).to include("already queued or in progress")
      end

      it "does not enqueue an agent run when pausing" do
        expect(pr.auto_continue_paused).to be false

        expect {
          post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }
        }.not_to change(AgentRun, :count)
      end

      it "cancels queued automatic runs when pausing" do
        queued_run = create(:agent_run, :queued, :automatic, project: project,
          source_pull_request_number: 77, custom_prompt: "Fix PR")

        post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        expect(queued_run.reload.status).to eq("cancelled")
      end

      it "does not cancel queued manual runs when pausing" do
        manual_run = create(:agent_run, :queued, :manual, project: project,
          source_pull_request_number: 77, custom_prompt: "Manual fix")

        post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        expect(manual_run.reload.status).to eq("queued")
      end

      it "does not cancel runs when resuming" do
        pr.update!(auto_continue_paused: true)
        queued_run = create(:agent_run, :queued, :automatic, project: project,
          source_pull_request_number: 77, custom_prompt: "Fix PR")

        post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: pr.id }

        expect(queued_run.reload.status).to eq("queued")
      end

      it "redirects with error when no pull request selected" do
        post toggle_auto_continue_pause_project_agent_runs_path(project)
        expect(response).to redirect_to(project_path(project))
        expect(flash[:alert]).to include("Please select a pull request")
      end

      it "redirects with error when pull_request_id is invalid" do
        post toggle_auto_continue_pause_project_agent_runs_path(project), params: { pull_request_id: 999_999 }
        expect(response).to redirect_to(project_path(project))
        expect(flash[:alert]).to include("Please select a pull request")
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/cancel" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        agent_run = create(:agent_run, :running, project: project)
        post cancel_project_agent_run_path(project, agent_run)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "cancels an active run and enqueues background cleanup" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          post cancel_project_agent_run_path(project, agent_run)
        }.to have_enqueued_job(AgentRunCancellationJob).with(agent_run.id)

        expect(agent_run.reload.status).to eq("cancelled")
        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:notice]).to eq("Agent run cancelled.")
      end

      it "cancels a paused run and enqueues background cleanup" do
        agent_run = create(:agent_run, project: project, status: "paused", paused_at: Time.current,
          guardrail_violation_type: "cost_limit")

        expect {
          post cancel_project_agent_run_path(project, agent_run)
        }.to have_enqueued_job(AgentRunCancellationJob).with(agent_run.id)

        expect(agent_run.reload.status).to eq("cancelled")
        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:notice]).to eq("Agent run cancelled.")
      end

      it "redirects with notice when run is no longer active" do
        agent_run = create(:agent_run, :failed, project: project)

        post cancel_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:notice]).to eq("Agent run is no longer active.")
      end

      it "does not allow cancelling runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, :without_creator, account: other_account)
        other_project = create(:project, :without_creator, account: other_account, github_token: other_token)
        other_run = create(:agent_run, :running, project: other_project)

        post cancel_project_agent_run_path(other_project, other_run)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/resume" do
    context "when authenticated" do
      before { sign_in user }

      it "re-queues a paused run and enqueues ProcessRunQueueJob" do
        agent_run = create(:agent_run, project: project, status: "paused", paused_at: Time.current,
          guardrail_violation_type: "time_limit", temporal_workflow_id: "workflow-123", temporal_run_id: "run-123")
        allow(AgentRuns::Cancel).to receive(:call)

        expect {
          post resume_project_agent_run_path(project, agent_run)
        }.to have_enqueued_job(ProcessRunQueueJob)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:notice]).to eq("Agent run resumed and re-queued.")
        expect(AgentRuns::Cancel).to have_received(:call).with(agent_run: agent_run, skip_status_update: true)

        agent_run.reload
        expect(agent_run.status).to eq("queued")
        expect(agent_run.paused_at).to be_nil
        expect(agent_run.guardrail_violation_type).to be_nil
        expect(agent_run.temporal_workflow_id).to be_nil
        expect(agent_run.temporal_run_id).to be_nil
        expect(OrchestrationDecision.last.actor).to eq("manual_resume")
      end

      it "rejects non-paused runs" do
        agent_run = create(:agent_run, :running, project: project)

        post resume_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:alert]).to eq("Only paused runs can be resumed.")

        agent_run.reload
        expect(agent_run.status).to eq("running")
      end

      it "does not resume when the previous workflow cannot be cancelled" do
        agent_run = create(:agent_run, project: project, status: "paused", paused_at: Time.current,
          guardrail_violation_type: "time_limit", temporal_workflow_id: "workflow-123", temporal_run_id: "run-123")
        allow(AgentRuns::Cancel).to receive(:call).and_raise(StandardError, "Temporal RPC error")

        expect {
          post resume_project_agent_run_path(project, agent_run)
        }.not_to have_enqueued_job(ProcessRunQueueJob)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:alert]).to eq("Unable to resume until the previous execution is cancelled. Please try again.")

        agent_run.reload
        expect(agent_run.status).to eq("paused")
        expect(agent_run.temporal_workflow_id).to eq("workflow-123")
        expect(agent_run.temporal_run_id).to eq("run-123")
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/terminate" do
    context "when authenticated" do
      before { sign_in user }

      it "cancels a paused run without marking it failed" do
        agent_run = create(:agent_run, project: project, status: "paused", paused_at: Time.current,
          guardrail_violation_type: "cost_limit")
        allow(AgentRuns::Cancel).to receive(:call)

        post terminate_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:notice]).to eq("Agent run terminated.")
        expect(AgentRuns::Cancel).to have_received(:call).with(agent_run: agent_run, skip_status_update: true)

        agent_run.reload
        expect(agent_run.status).to eq("cancelled")
        expect(agent_run.error_message).to include("cost_limit")
      end

      it "uses the persisted violation context when the guardrail type column is blank" do
        agent_run = create(:agent_run, project: project, status: "paused", paused_at: Time.current,
          guardrail_violation_type: nil, guardrail_context: { "violation_type" => "time_limit" })
        allow(AgentRuns::Cancel).to receive(:call)

        post terminate_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))

        agent_run.reload
        expect(agent_run.status).to eq("cancelled")
        expect(agent_run.error_message).to eq("Terminated after guardrail violation: time_limit")
      end

      it "falls back to unknown when no guardrail type is stored" do
        agent_run = create(:agent_run, project: project, status: "paused", paused_at: Time.current,
          guardrail_violation_type: nil, guardrail_context: {})
        allow(AgentRuns::Cancel).to receive(:call)

        post terminate_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))

        agent_run.reload
        expect(agent_run.status).to eq("cancelled")
        expect(agent_run.error_message).to eq("Terminated after guardrail violation: unknown")
      end

      it "rejects non-paused runs" do
        agent_run = create(:agent_run, :completed, project: project)

        post terminate_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:alert]).to eq("The agent run state changed and could not be terminated.")
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/retry" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        agent_run = create(:agent_run, :failed, project: project)
        post retry_project_agent_run_path(project, agent_run)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "creates a new queued run from a failed run" do
        agent_run = create(:agent_run, :failed, project: project, agent_type: "claude_code")

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.status).to eq("queued")
        expect(new_run.project).to eq(project)
        expect(new_run.issue).to eq(agent_run.issue)
        expect(new_run.agent_type).to eq("claude_code")
        expect(response).to redirect_to(project_agent_run_path(project, new_run))
      end

      it "marks the original run as retried" do
        agent_run = create(:agent_run, :failed, project: project)

        post retry_project_agent_run_path(project, agent_run)

        expect(agent_run.reload.status).to eq("retried")
      end

      it "keeps the primary retry action on the original agent type" do
        user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: false)
        agent_run = create(:agent_run, :failed, project: project, agent_type: "cursor")

        post retry_project_agent_run_path(project, agent_run)

        expect(AgentRun.last.agent_type).to eq("cursor")
      end

      it "creates a retry using a different configured runner" do
        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])
        project.effective_owner.runners.create!(runner_key: "cursor")
        agent_run = create(:agent_run, :failed, project: project, agent_type: "claude_code")

        post retry_project_agent_run_path(project, agent_run), params: { runner: "cursor" }

        new_run = AgentRun.last
        expect(new_run.agent_type).to eq("cursor")
        expect(response).to redirect_to(project_agent_run_path(project, new_run))
      end

      it "rejects retrying with an unavailable explicit runner" do
        user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: false)
        agent_run = create(:agent_run, :failed, project: project, agent_type: "claude_code")

        expect {
          post retry_project_agent_run_path(project, agent_run), params: { runner: "cursor" }
        }.not_to change(AgentRun, :count)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("selected runner is not available")
      end

      it "rejects retrying with a disabled explicit runner identifier" do
        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude opencode])
        owner = project.effective_owner
        api_key = create(:runner_api_key, user: owner, api_service_type: "openrouter")
        disabled_runner = create_opencode_runner_entry(user: owner, api_key: api_key, name: "Disabled Kimi",
          model: "moonshotai/kimi-k2-0905", enabled_for_agent_runs: false)
        create_opencode_runner_entry(user: owner, api_key: api_key, name: "Enabled Opus", model: "anthropic/claude-opus-4.1")
        agent_run = create(:agent_run, :failed, project: project, agent_type: "opencode")

        expect {
          post retry_project_agent_run_path(project, agent_run), params: { runner: disabled_runner.routing_key }
        }.not_to change(AgentRun, :count)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("selected runner is not available")
      end

      it "resolves plain runner keys against enabled retry providers" do
        allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude opencode])
        owner = project.effective_owner
        api_key = create(:runner_api_key, user: owner, api_service_type: "openrouter")
        owner.runners.create!(runner_key: "opencode", enabled_for_agent_runs: false)
        enabled_runner = create_opencode_runner_entry(
          user: owner,
          api_key: api_key,
          name: "Enabled Kimi",
          model: "moonshotai/kimi-k2-0905"
        )
        agent_run = create(:agent_run, :failed, project: project, agent_type: "claude_code")

        expect {
          post retry_project_agent_run_path(project, agent_run), params: { runner: "opencode" }
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.agent_type).to eq("opencode")
        expect(new_run.runner_id).to eq(enabled_runner.id)
      end

      it "preserves user-supplied custom_prompt from the original run" do
        agent_run = create(:agent_run, :failed, :with_custom_prompt, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.id).not_to eq(agent_run.id)
        expect(new_run.custom_prompt).to eq(agent_run.custom_prompt)
      end

      it "clears auto-generated prompt so it is rebuilt on retry" do
        agent_run = create(:agent_run, :failed, :existing_pr, project: project, custom_prompt: "# Task\n\nAuto-generated prompt")
        create(:agent_run_phase, agent_run: agent_run, phase_key: "prepare_pr_prompt", phase_group: "prompt")

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.id).not_to eq(agent_run.id)
        expect(new_run.custom_prompt).to be_nil
      end

      it "clears auto-generated prompt even when prepare_pr_prompt phase failed" do
        agent_run = create(:agent_run, :failed, :existing_pr, project: project, custom_prompt: "# Task\n\nStale prompt")
        create(:agent_run_phase, agent_run: agent_run, phase_key: "prepare_pr_prompt", phase_group: "prompt", status: "failed")

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.id).not_to eq(agent_run.id)
        expect(new_run.custom_prompt).to be_nil
      end

      it "preserves source_pull_request_number from the original run" do
        agent_run = create(:agent_run, :failed, :existing_pr, project: project)

        post retry_project_agent_run_path(project, agent_run)

        new_run = AgentRun.last
        expect(new_run.source_pull_request_number).to eq(agent_run.source_pull_request_number)
      end

      it "enqueues ProcessRunQueueJob" do
        agent_run = create(:agent_run, :failed, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "redirects with success notice" do
        agent_run = create(:agent_run, :failed, project: project)

        post retry_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, AgentRun.last))
        follow_redirect!
        expect(response.body).to include("retry")
      end

      it "allows retrying a timed-out run" do
        agent_run = create(:agent_run, :timeout, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        expect(AgentRun.last.status).to eq("queued")
      end

      it "allows retrying a cancelled run" do
        agent_run = create(:agent_run, :cancelled, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(AgentRun, :count).by(1)

        expect(AgentRun.last.status).to eq("queued")
      end

      it "records a retry decision event" do
        agent_run = create(:agent_run, :failed, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.to change(OrchestrationDecision, :count).by(1)

        event = OrchestrationDecision.last
        expect(event.actor).to eq("manual_retry")
        expect(event.context["decision_status"]).to eq("applied")
        expect(event.outputs["new_agent_run_id"]).to eq(AgentRun.last.id)
      end

      it "rejects retrying an active run" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          post retry_project_agent_run_path(project, agent_run)
        }.not_to change(AgentRun, :count)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Only finished runs can be retried")
      end

      it "does not allow retrying runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, :without_creator, account: other_account)
        other_project = create(:project, :without_creator, account: other_account, github_token: other_token)
        other_run = create(:agent_run, :failed, project: other_project)

        post retry_project_agent_run_path(other_project, other_run)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /projects/:project_id/agent_runs/:id/refresh_auth" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        post refresh_auth_project_agent_run_path(project, agent_run)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "redirects when run is not auth_expired" do
        agent_run = create(:agent_run, :failed, project: project)

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "abc123" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Only runs with expired authentication")
      end

      it "redirects when auth token is blank" do
        agent_run = create(:agent_run, :auth_expired, project: project)

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "  " }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Please provide an authentication token")
      end

      it "creates a new queued run and marks original as retried on success" do
        agent_run = create(:agent_run, :auth_expired, project: project, agent_type: "claude_code")
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
        end

        expect {
          post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_token: "valid-token" }
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.status).to eq("queued")
        expect(new_run.project).to eq(project)
        expect(new_run.issue).to eq(agent_run.issue)
        expect(new_run.agent_type).to eq("claude_code")
        expect(new_run.trigger_type).to eq("manual")
        expect(agent_run.reload.status).to eq("retried")
        expect(response).to redirect_to(project_agent_run_path(project, new_run))
        expect(OrchestrationDecision.last.actor).to eq("refresh_auth_retry")
        without_partial_double_verification do
          expect(AgentHarness).to have_received(:refresh_auth).with(:claude, token: "valid-token")
        end
      end

      it "still accepts the legacy auth_code parameter as a token" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
        end

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_code: "legacy-token" }

        without_partial_double_verification do
          expect(AgentHarness).to have_received(:refresh_auth).with(:claude, token: "legacy-token")
        end
      end

      it "enqueues ProcessRunQueueJob on success" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
        end

        expect {
          post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_token: "valid-token" }
        }.to have_enqueued_job(ProcessRunQueueJob)
      end

      it "redirects with alert when auth_provider is missing" do
        agent_run = create(:agent_run, :auth_expired, project: project, auth_provider: nil)

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_token: "valid-token" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Unable to determine authentication runner")
      end

      it "redirects with alert when refresh_auth is not supported" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        allow(AgentHarness).to receive(:respond_to?).and_call_original
        allow(AgentHarness).to receive(:respond_to?).with(:refresh_auth).and_return(false)

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_token: "valid-token" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Re-authentication is not supported")
      end

      it "redirects with alert when the runner does not support refresh_auth" do
        agent_run = create(:agent_run, :auth_expired, project: project, auth_provider: "codex")
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
            .and_raise(NotImplementedError, "Runner codex uses api_key auth and does not support credential refresh")
        end

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_token: "valid-token" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Re-authentication is not supported for this runner")
      end

      it "redirects with alert on AgentHarness::AuthenticationError" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
            .and_raise(AgentHarness::AuthenticationError, "Invalid code")
        end

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_token: "bad-token" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Re-authentication failed")
        expect(response.body).to include("Invalid code")
      end

      it "redirects with alert on AgentHarness::Error" do
        agent_run = create(:agent_run, :auth_expired, project: project)
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
            .and_raise(AgentHarness::Error, "Runner unavailable")
        end

        post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_token: "some-token" }

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        follow_redirect!
        expect(response.body).to include("Re-authentication failed")
        expect(response.body).to include("Runner unavailable")
      end

      it "clears auto-generated prompt on refresh_auth retry" do
        agent_run = create(:agent_run, :auth_expired, :existing_pr, project: project, custom_prompt: "# Task\n\nStale prompt")
        create(:agent_run_phase, agent_run: agent_run, phase_key: "prepare_pr_prompt", phase_group: "prompt")
        without_partial_double_verification do
          allow(AgentHarness).to receive(:refresh_auth)
        end

        expect {
          post refresh_auth_project_agent_run_path(project, agent_run), params: { auth_token: "valid-token" }
        }.to change(AgentRun, :count).by(1)

        new_run = AgentRun.last
        expect(new_run.id).not_to eq(agent_run.id)
        expect(new_run.custom_prompt).to be_nil
      end

      it "does not allow refreshing runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, :without_creator, account: other_account)
        other_project = create(:project, :without_creator, account: other_account, github_token: other_token)
        other_run = create(:agent_run, :auth_expired, project: other_project)

        post refresh_auth_project_agent_run_path(other_project, other_run), params: { auth_code: "abc" }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  def create_opencode_runner_entry(user:, api_key:, name:, model:, **attrs)
    user.runners.create!(
      runner_key: "opencode",
      auth_type: "api_key",
      provider_api_key: api_key,
      name: name,
      enabled_for_agent_runs: true,
      config: { "opencode" => { "api_provider" => "openrouter", "model" => model } },
      **attrs
    )
  end

  def create_opencode_fallback_runner(user:, name:, model:)
    api_key = create(:runner_api_key, user: user, api_service_type: "openrouter")
    create_opencode_runner_entry(user: user, api_key: api_key, name: name, model: model)
  end

  def runner_attempt(runner, error_type, error_message)
    {
      "runner" => runner,
      "success" => false,
      "error_type" => error_type,
      "error_message" => error_message
    }
  end

  describe "POST /projects/:project_id/agent_runs/:id/diagnose_error" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        agent_run = create(:agent_run, :failed, project: project)
        post diagnose_error_project_agent_run_path(project, agent_run)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "enqueues a diagnosis job for a failed run" do
        agent_run = create(:agent_run, :failed, project: project)

        expect {
          post diagnose_error_project_agent_run_path(project, agent_run)
        }.to have_enqueued_job(DiagnoseErrorJob).with(agent_run.id)

        expect(agent_run.reload.diagnosis_status).to eq("in_progress")
        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
      end

      it "rejects diagnosis for a running run" do
        agent_run = create(:agent_run, :running, project: project)

        post diagnose_error_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:alert]).to include("Only finished runs")
      end

      it "rejects diagnosis for a run without errors" do
        agent_run = create(:agent_run, :completed, project: project)

        post diagnose_error_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:alert]).to include("Only runs with errors")
      end

      it "rejects diagnosis when already in progress" do
        agent_run = create(:agent_run, :failed, project: project, diagnosis_status: "in_progress")

        post diagnose_error_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:alert]).to include("already in progress")
      end

      it "rejects diagnosis when already completed" do
        agent_run = create(:agent_run, :failed, project: project, diagnosis_status: "completed")

        post diagnose_error_project_agent_run_path(project, agent_run)

        expect(response).to redirect_to(project_agent_run_path(project, agent_run))
        expect(flash[:notice]).to include("already been completed")
      end

      it "does not allow diagnosing runs from other accounts" do
        other_account = create(:account)
        other_token = create(:github_token, :without_creator, account: other_account)
        other_project = create(:project, :without_creator, account: other_account, github_token: other_token)
        other_run = create(:agent_run, :failed, project: other_project)

        post diagnose_error_project_agent_run_path(other_project, other_run)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  def parsed_html
    Nokogiri::HTML(response.body)
  end

  def goal_cell_for_run(document, run)
    cell_for_run(document, run, "Goal")
  end

  def row_for_run(document, run)
    row = document.at_css(%(tr##{ActionView::RecordIdentifier.dom_id(run)}))

    expect(row).to be_present
    row
  end

  def cell_for_run(document, run, header_text)
    row = row_for_run(document, run)
    index = column_index(document, header_text)

    expect(index).not_to be_nil, "Expected a '#{header_text}' header column in the table but none was found"

    cell = row.css("td")[index]

    expect(cell).to be_present
    cell
  end

  def goal_column_index(document)
    column_index(document, "Goal")
  end

  def column_index(document, header_text)
    document.css("table thead th").find_index { |header| header.text.squish == header_text }
  end
end
