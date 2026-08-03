# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard" do
  describe "GET /dashboard" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get dashboard_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      let(:account) { create(:account, name: "Test Company") }
      let(:user) { create(:user, account: account, name: "John Doe") }
      let(:project) { create(:project, account: account, created_by: user) }

      before { sign_in user }

      it "renders the dashboard" do
        get dashboard_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Dashboard")
      end

      it "displays the user name" do
        get dashboard_path
        expect(response.body).to include("John Doe")
      end

      it "displays the account name" do
        get dashboard_path
        expect(response.body).to include("Test Company")
      end

      it "renders retry-limited issues as a neutral empty dashboard card", :aggregate_failures do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        card = doc.at_css("[data-testid='retry-limited-issues-card']")
        expect(card).to be_present

        heading = card.at_xpath(".//h3[normalize-space()='Retry-limited issues']")
        expect(heading).to be_present

        expect(card["class"]).to include("border-gray-200")
        expect(card["class"]).to include("bg-white")
        expect(heading["class"]).to include("text-gray-900")
        expect(response.body).to include("No retry-limited issues or PRs at the moment.")
      end

      it "calls out retry-limited issues when operator action is available", :aggregate_failures do
        create(
          :issue,
          project: project,
          runner_retry_abandoned_at: Time.current,
          runner_retry_abandon_reason: "All runners reached the retry cap"
        )

        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        card = doc.at_css("[data-testid='retry-limited-issues-card']")
        expect(card).to be_present

        heading = card.at_xpath(".//h3[normalize-space()='Retry-limited issues']")
        expect(heading).to be_present

        expect(card["class"]).to include("border-orange-200")
        expect(card["class"]).to include("bg-orange-50")
        expect(heading["class"]).to include("text-orange-900")
        expect(response.body).to include("Clear the flag to retry, or run them manually.")
        expect(response.body).to include("Retry Cap")
      end

      it "surfaces exception incidents from the dashboard header" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        link = doc.at_css("[data-testid='dashboard-exception-incidents-link']")

        expect(link).to be_present
        expect(link["href"]).to eq(exception_incidents_path)
        expect(link.text.strip).to eq("Exception incidents")
      end

      it "includes exception incidents in the desktop navigation" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        desktop_nav_link = doc.at_css("#operations-menu a[href='#{exception_incidents_path}']")

        expect(desktop_nav_link).to be_present
        expect(desktop_nav_link["href"]).to eq(exception_incidents_path)
        expect(desktop_nav_link.text.strip).to eq("Exception incidents")
      end

      it "includes settings in the mobile menu" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        mobile_settings_link = doc.at_css("#mobile-menu a[href='#{edit_user_settings_path}']")

        expect(mobile_settings_link).to be_present
        expect(mobile_settings_link.text.strip).to eq("Settings")
      end

      it "includes exception incidents in the mobile menu" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        mobile_exception_link = doc.at_css("#mobile-menu [data-testid='mobile-exception-incidents-link']")

        expect(mobile_exception_link).to be_present
        expect(mobile_exception_link["href"]).to eq(exception_incidents_path)
        expect(mobile_exception_link.text.strip).to eq("Exception incidents")
      end

      it "renders the user email dropdown in the desktop navbar" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        menu_button = doc.at_css("#user-menu-button")
        menu = doc.at_css("#user-menu")

        expect(menu_button).to be_present
        expect(menu_button.text).to include(user.email)
        expect(menu_button["aria-expanded"]).to eq("false")

        expect(menu).to be_present
        expect(menu["class"]).to include("hidden")
        menu_labels = menu.css("a, form button").map { |node| node.text.strip }
        menu_roles = menu.css("a, form button").map { |node| node["role"] }

        expect(menu_labels).to include("Settings", "Account", "Sign out")
        expect(menu_roles).to all(eq("menuitem"))
        expect(menu.css("a").map { |node| node["data-action"] }).to all(eq("dropdown#close"))
      end

      it "removes settings and account actions from the desktop top-level nav" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        desktop_nav = doc.at_xpath("//nav//div[contains(@class, 'hidden') and contains(@class, 'lg:flex')]")
        top_level_labels = desktop_nav.xpath("./a|./form/button").map { |node| node.text.strip }

        expect(top_level_labels).not_to include("Settings")
        expect(top_level_labels).not_to include("Account")
        expect(top_level_labels).not_to include("Tenant")
        expect(top_level_labels).not_to include("Sign out")
      end

      it "shows the run phase breakdown section via metrics frame" do
        get dashboard_metrics_path(time_range: "cumulative")

        expect(response.body).to include("Run Phase Breakdown")
        expect(response.body).to include("Average End-to-End Composition")
        expect(response.body).to include('aria-label="Average end-to-end composition by phase"')
      end

      it "shows the stacked daily agent runs chart via metrics frame" do
        create(:agent_run, :completed, project: project, created_at: 1.day.ago)
        create(:agent_run, :failed, project: project, created_at: 1.day.ago)

        get dashboard_metrics_path(time_range: "cumulative")

        doc = Nokogiri::HTML(response.body)
        chart = doc.at_css("div#daily-runs-chart")

        expect(response.body).to include("Agent Runs per Day")
        expect(chart).to be_present
      end

      it "renders deferred turbo frame sources for dashboard widgets", :aggregate_failures do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("[data-controller~='dashboard-frames']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-queue-preview[src]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-metrics[data-dashboard-frames-src='#{dashboard_metrics_path(time_range: "cumulative")}']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-performance[data-dashboard-frames-src='#{dashboard_performance_path(time_range: "cumulative", status: "all", goal: "all")}']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-decision-metrics[data-dashboard-frames-src='#{dashboard_decision_metrics_path(time_range: "cumulative")}']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-eligibility-breakdown[data-dashboard-frames-src='#{dashboard_eligibility_breakdown_path}']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-auth-health[data-dashboard-frames-src='#{dashboard_auth_health_path}']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-knowledge-stats[data-dashboard-frames-src='#{dashboard_knowledge_stats_path}']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-runner-health[data-dashboard-frames-src='#{dashboard_runner_health_path}']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-queue-health[data-dashboard-frames-src='#{dashboard_queue_health_path}']")).to be_present
      end

      it "renders dashboard widget frames without eager turbo loading attributes", :aggregate_failures do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("turbo-frame#dashboard-metrics[loading]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-performance[loading]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-decision-metrics[loading]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-eligibility-breakdown[loading]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-auth-health[loading]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-knowledge-stats[loading]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-runner-health[loading]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-queue-health[loading]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-metrics[src]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-performance[src]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-decision-metrics[src]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-eligibility-breakdown[src]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-auth-health[src]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-knowledge-stats[src]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-runner-health[src]")).not_to be_present
        expect(doc.at_css("turbo-frame#dashboard-queue-health[src]")).not_to be_present
      end

      it "does not compute the eligibility breakdown during the dashboard shell request" do
        allow(Dashboard::EligibilityBreakdown).to receive(:call).and_call_original

        get dashboard_path

        expect(Dashboard::EligibilityBreakdown).not_to have_received(:call)
      end

      it "renders runner health above queue health in the dashboard shell" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("[data-controller~='dashboard-frames']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-runner-health[data-dashboard-frames-src='#{dashboard_runner_health_path}']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-queue-health[data-dashboard-frames-src='#{dashboard_queue_health_path}']")).to be_present
        runner_frame = doc.at_css("turbo-frame#dashboard-runner-health")
        queue_frame = doc.at_css("turbo-frame#dashboard-queue-health")

        expect(runner_frame).to be_present
        expect(queue_frame).to be_present
        expect(runner_frame.path).to be < queue_frame.path
      end

      it "wires queue health and frame serialization on the dashboard shell" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("[data-controller~='dashboard-frames']")).to be_present
        expect(doc.at_css("turbo-frame#dashboard-queue-health[src]")).not_to be_present
      end

      it "wires the deferred github credential health turbo frame" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        frame = doc.at_css("turbo-frame#dashboard-github-health[data-dashboard-frames-src='#{dashboard_github_health_path}']")
        expect(frame).to be_present
        expect(frame["loading"]).to be_nil
        expect(frame["src"]).to be_nil
      end

      it "wires the deferred auth-health turbo frame" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        frame = doc.at_css("turbo-frame#dashboard-auth-health[data-dashboard-frames-src='#{dashboard_auth_health_path}']")

        expect(frame).to be_present
        expect(frame["loading"]).to be_nil
        expect(frame["src"]).to be_nil
      end

      it "renders the auth-health banner via the deferred frame when Claude auth needs attention" do
        allow(Runners::AuthHealth).to receive(:call).and_return([
          Runners::AuthHealth::Result.new(
            runner: "Claude",
            runner_key: "claude",
            owner_name: user.name,
            owner_email: user.email,
            valid: false,
            expires_at: 1.hour.ago,
            source: :host_forwarded,
            error: "Session expired"
          )
        ])

        get dashboard_auth_health_path

        doc = Nokogiri::HTML(response.body)
        frame = doc.at_css("turbo-frame#dashboard-auth-health")
        banner = doc.at_css("[data-testid='dashboard-auth-health-banner']")

        expect(frame).to be_present
        expect(banner).to be_present
        expect(banner.text).to include("Claude auth health needs attention")
        expect(banner.text).to include("Session expired")
      end

      it "shows live metrics section with active runs" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 42)

        get dashboard_path

        expect(response.body).to include("Live Metrics")
        expect(response.body).to include("Active Runs")
        expect(response.body).not_to include("Active Containers")
        expect(response.body).not_to include("Warm Containers")
        expect(response.body).not_to include("Total Projects")
        expect(response.body).not_to include("Active Projects")
        expect(response.body).to include("Recent Activity")
      end

      it "links each live metrics tile to the matching filtered agent runs index" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "queued")
        create(:agent_run, project: project, status: "queued", temporal_workflow_id: "wf-claimed")
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago)
        create(:agent_run, project: project, status: "failed", completed_at: 1.minute.ago)
        create(:agent_run, project: project, goal: "create_pr", status: "running", started_at: 1.minute.ago)

        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        hrefs = doc.css("a").map { |a| a["href"].to_s }

        expect(hrefs).to include(agent_runs_path(q: { status_eq: "running" }))
        expect(hrefs).to include(agent_runs_path(q: { status_eq: "queued", temporal_workflow_id_null: true }))
        expect(hrefs).to include(agent_runs_path(q: { status_eq: "completed", completed_at_gteq: Time.current.beginning_of_day.iso8601 }))
        expect(hrefs).to include(agent_runs_path(q: { status_in: AgentRun::FAILURE_STATUSES, completed_at_gteq: Time.current.beginning_of_day.iso8601 }))
        expect(hrefs).to include(agent_runs_path(q: { goal_eq: "create_pr", status_eq: "running" }))
      end

      it "does not include claimed queued runs when filtering by the Queued tile link" do
        unclaimed = create(:agent_run, project: project, status: "queued")
        claimed = create(:agent_run, project: project, status: "queued", temporal_workflow_id: "wf-1")

        get agent_runs_path, params: { q: { status_eq: "queued", temporal_workflow_id_null: true } }

        expect(response.body).to include(project_agent_run_path(project, unclaimed))
        expect(response.body).not_to include(project_agent_run_path(project, claimed))
      end

      it "shows upcoming queue positions only for the signed-in user's projects" do
        owned_project = create(:project, account: account, created_by: user, owner: "visible-owner", repo: "visible-repo")
        other_user = create(:user, account: account)
        hidden_project = create(:project, account: account, created_by: other_user, owner: "hidden-owner", repo: "hidden-repo")
        visible_issue = create(:issue, project: owned_project, github_number: 77, title: "Tighten queue preview context")

        create(:agent_run, :queued, project: owned_project, issue: visible_issue, created_at: 2.minutes.ago)
        create(:agent_run, :queued, :manual, project: hidden_project, created_at: 1.minute.ago)

        get dashboard_path
        doc = Nokogiri::HTML(response.body)
        queue_section = doc.at_xpath("//h3[normalize-space(text())='Upcoming Queue']/ancestor::div[contains(@class, 'rounded-lg')][1]")

        expect(response.body).to include("Upcoming Queue")
        expect(response.body).to include("visible-owner/visible-repo")
        expect(response.body).to include("Issue #77")
        expect(queue_section).to be_present

        headers = queue_section.css("table thead th").map { |node| node.text.strip }
        expect(headers).to include("Context")
        expect(headers).not_to include("Created")
        expect(headers).not_to include("Waiting")
        expect(headers).to include("Actions")
        expect(response.body).not_to include("hidden-owner/hidden-repo")
      end

      it "renders Cancel and View actions for cancellable queued runs in the upcoming queue" do
        issue = create(:issue, project: project, github_number: 91, title: "Cancel from the queue")
        run = create(:agent_run, :queued, project: project, issue: issue, created_at: 2.minutes.ago)

        get dashboard_path

        document = Nokogiri::HTML(response.body)
        queue_section = document.at_xpath("//h3[normalize-space(text())='Upcoming Queue']/ancestor::div[contains(@class, 'rounded-lg')][1]")
        row = queue_section.at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :queue_preview_row)}"]))

        expect(row).to be_present
        expect(row.css("a").map { |a| a["href"] }).to include(project_agent_run_path(project, run))
        cancel_form = row.at_css("form[action='#{dashboard_cancel_run_path(run)}']")
        expect(cancel_form).to be_present
        expect(cancel_form["method"]).to eq("post")
        expect(cancel_form.at_css("input[name='source']")&.[]("value")).to eq("queue_preview")
        expect(cancel_form.at_css("button")&.text).to include("Cancel")
      end

      it "disables Turbo navigation for the project link in the upcoming queue" do
        issue = create(:issue, project: project, github_number: 92, title: "Navigate from the queue")
        run = create(:agent_run, :queued, project: project, issue: issue, created_at: 2.minutes.ago)

        get dashboard_path

        document = Nokogiri::HTML(response.body)
        queue_section = document.at_xpath("//h3[normalize-space(text())='Upcoming Queue']/ancestor::div[contains(@class, 'rounded-lg')][1]")
        row = queue_section.at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :queue_preview_row)}"]))
        project_link = row.at_css(%(a[href="#{project_path(project)}"]))

        expect(project_link).to be_present
        expect(project_link["data-turbo"]).to eq("false")
      end

      it "does not render a Cancel button in the upcoming queue for users who cannot run agents" do
        viewer = create(:user, :viewer, account: account)
        sign_in viewer

        viewer_project = create(:project, account: account, created_by: viewer, owner: "viewer-octo", repo: "queue")
        run = create(:agent_run, :queued, project: viewer_project, created_at: 2.minutes.ago)

        get dashboard_path

        document = Nokogiri::HTML(response.body)
        queue_section = document.at_xpath("//h3[normalize-space(text())='Upcoming Queue']/ancestor::div[contains(@class, 'rounded-lg')][1]")
        row = queue_section.at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :queue_preview_row)}"]))

        expect(row).to be_present
        expect(row.css("a").map { |a| a["href"] }).to include(project_agent_run_path(viewer_project, run))
        expect(row.at_css("form")).to be_nil
        expect(response.body).not_to include(dashboard_cancel_run_path(run))
      end

      it "shows orphaned queued projects for the account fallback owner" do
        orphaned_project = create(:project, account: account, created_by: nil, owner: "fallback-owner", repo: "orphaned-repo")

        create(:agent_run, :queued, :manual, project: orphaned_project)

        get dashboard_path

        expect(response.body).to include("fallback-owner/orphaned-repo")
      end

      it "shows active runs and recent activity scoped to the account" do
        create(:agent_run, project: project, status: "running", started_at: 5.minutes.ago)
        create(:agent_run, project: project, status: "completed", completed_at: 1.minute.ago, duration_seconds: 42)

        get dashboard_path

        expect(response.body).to include(project.full_name)
        expect(response.body).to include("42s")
      end

      it "shows knowledge runner health and pipeline metrics" do
        create(:runner_state, :rate_limited, user: user, runner_name: user.settings.kb_embedding_runner)
        create(:runner_state, user: user, runner_name: user.settings.kb_chat_runner, failure_count: 2)
        create(:knowledge_run, :completed, project: project, operation_type: "embedding", final_runner: "openai")
        create(:knowledge_run, :failed, :decision_drafting, project: project, runner_attempts: [ { "runner" => "claude" } ])

        get dashboard_knowledge_stats_path

        expect(response.body).to include("Runner Health")
        expect(response.body).to include("Unavailable")
        expect(response.body).to include("LLM Pipeline Metrics (Last 30 Days)")
        expect(response.body).to include("Decision Drafting")
        expect(response.body).to include("Embedding")
      end

      it "shows unavailable helper copy when both runner groups are down" do
        create(:runner_state, :rate_limited, user: user, runner_name: user.settings.kb_embedding_runner)
        create(:runner_state, :circuit_open, user: user, runner_name: user.settings.kb_chat_runner)

        get dashboard_knowledge_stats_path

        expect(response.body).to include("Knowledge capabilities are unavailable because both runner groups are down.")
        expect(response.body).not_to include("Knowledge capabilities are degraded while one runner group remains available.")
      end

      it "shows the runner column in the active runs table" do
        runner = create(:runner, user: user, runner_key: "codex")
        run = create(:agent_run, :running, project: project, runner: runner, final_runner: runner.routing_key)

        get dashboard_path

        document = Nokogiri::HTML(response.body)
        table = document.at_css("#active-runs table")

        expect(table).to be_present
        expect(table.css("thead th").map { |header| header.text.squish }).to include("Runner")

        row = document.at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :dashboard_row)}"]))

        expect(row).to be_present
        expect(row.text).to include(runner.display_name)
      end

      it "shows the priority column in the active runs table" do
        issue = create(:issue, project: project, labels: [ "P1" ])
        run = create(:agent_run, :running, project: project, issue: issue)
        preloaded_runs = []

        allow(AgentRun).to receive(:preload_source_pull_requests).and_wrap_original do |original, runs|
          preloaded_runs << runs.to_a
          original.call(runs)
        end

        get dashboard_path

        document = Nokogiri::HTML(response.body)
        table = document.at_css("#active-runs table")

        expect(table).to be_present
        expect(table.css("thead th").map { |header| header.text.squish }).to include("Priority")
        expect(preloaded_runs).to include(include(have_attributes(id: run.id)))

        row = document.at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :dashboard_row)}"]))

        expect(row).to be_present
        expect(row.text).to include("6 - P1")
      end

      it "shows the final runner label for legacy fallback runs in the active runs table" do
        initial_runner = create(:runner, user: user, runner_key: "codex")
        run = create(:agent_run, :running, project: project, runner: initial_runner, final_runner: "cursor")

        get dashboard_path

        row = Nokogiri::HTML(response.body).at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :dashboard_row)}"]))
        expect(row).to be_present
        expect(row.text).to include(Runner.display_name_for("cursor"))
      end

      it "shows review context tooltips in the active runs table" do
        source_pull_request = create(:issue, :pull_request, project: project, github_number: 87,
          title: "Tighten dashboard review context tooltips")
        run = create(:agent_run, :running, :review_goal, project: project, issue: nil,
          source_pull_request_number: source_pull_request.github_number)

        get dashboard_path

        document = Nokogiri::HTML(response.body)
        table = document.at_css("#active-runs table")
        headers = table.css("thead th").map { |header| header.text.squish }
        row = document.at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :dashboard_row)}"]))
        context_cell = row.css("td")[headers.index("Context")]
        context_tooltip_wrapper = context_cell.at_css('[data-controller="tooltip"]')
        context_tooltip = context_tooltip_wrapper&.at_css('span[role="tooltip"]')

        expect(row).to be_present
        expect(context_cell.text).to include("PR ##{run.source_pull_request_number}")
        expect(context_tooltip_wrapper).to be_present
        expect(context_tooltip).to be_present
        expect(context_tooltip.text).to include(source_pull_request.title)
      end

      it "does not add redundant goal tooltips in the active runs table" do
        run = create(:agent_run, :running, :review_goal, project: project, issue: nil,
          source_pull_request_number: 87)

        get dashboard_path

        document = Nokogiri::HTML(response.body)
        table = document.at_css("#active-runs table")
        headers = table.css("thead th").map { |header| header.text.squish }
        row = document.at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :dashboard_row)}"]))
        goal_cell = row.css("td")[headers.index("Goal")]
        goal_label = goal_cell.at_css("span.block.truncate")

        expect(row).to be_present
        expect(goal_cell.text).to include("Code Review")
        expect(goal_label).to be_present
        expect(goal_label["title"]).to be_nil
        expect(goal_cell.at_css('[data-controller="tooltip"]')).to be_nil
        expect(goal_cell.at_css('span[role="tooltip"]')).to be_nil
      end

      it "renders unsupported runner identifiers in the active runs table without error" do
        run = create(:agent_run, :running, project: project, runner: nil, final_runner: "api", agent_type: "api")

        get dashboard_path

        expect(response).to have_http_status(:ok)
        row = Nokogiri::HTML(response.body).at_css(%(tr[id="#{ActionView::RecordIdentifier.dom_id(run, :dashboard_row)}"]))
        expect(row).to be_present
        expect(row.text).to include("Api")
      end

      it "shows quality-paused projects on the dashboard" do
        project.update!(
          name: "Paused Project",
          quality_paused_at: 30.minutes.ago,
          quality_pause_metadata: {
            "composite_score" => 0.34,
            "threshold" => 0.5
          }
        )

        get dashboard_path

        expect(response.body).to include("Quality-paused projects")
        expect(response.body).to include("Paused Project")
        expect(response.body).to include("34.0%")
        expect(response.body).to include(edit_project_path(project))
      end

      it "shows the quality-paused notice above the queue and explains the empty queue" do
        project.update!(
          name: "Paused Project",
          auto_pick_enabled: true,
          quality_paused_at: 30.minutes.ago,
          quality_pause_metadata: { "composite_score" => 0.34, "threshold" => 0.5 }
        )

        get dashboard_path

        body = response.body
        expect(body.index("Quality-paused projects")).to be < body.index("Upcoming Queue")
        expect(body).not_to include("No queued runs for your projects.")
        expect(body).to include("no work is being queued")
      end

      it "does not blame the empty queue on a quality-paused project with auto-pick off" do
        project.update!(
          auto_pick_enabled: false,
          quality_paused_at: 30.minutes.ago,
          quality_pause_metadata: { "composite_score" => 0.34, "threshold" => 0.5 }
        )

        get dashboard_path

        expect(response.body).to include("Quality-paused projects")
        expect(response.body).to include("No queued runs for your projects.")
      end

      it "shows paused runs with resume actions on the dashboard" do
        issue = create(:issue, :pull_request, project: project,
          github_number: 88, title: "Handle paused runs better")
        run = create(:agent_run, :paused, project: project, issue: issue,
          source_pull_request_number: issue.github_number,
          guardrail_violation_type: "time_limit",
          guardrail_context: { "details" => "Execution time limit of 3600s exceeded" })

        get dashboard_path

        expect(response.body).to include("Paused Runs")
        expect(response.body).to include(project.full_name)
        expect(response.body).to include("PR ##{issue.github_number}")
        expect(response.body).to include("Execution time limit of 3600s exceeded")
        expect(response.body).to include(resume_project_agent_run_path(project, run))
        expect(response.body).to include("View run")
      end

      it "does not link viewers to quality pause review actions" do
        viewer = create(:user, :viewer, account: account)
        sign_in viewer

        project.update!(name: "Paused Project", quality_paused_at: 30.minutes.ago)

        get dashboard_path

        expect(response.body).to include("Paused Project")
        expect(response.body).to include(project_path(project))
        expect(response.body).not_to include(edit_project_path(project))
      end

      it "does not show quality-paused projects from other accounts" do
        other_account = create(:account)
        other_project = create(:project, account: other_account, quality_paused_at: 30.minutes.ago)

        get dashboard_path

        expect(response.body).not_to include(other_project.name)
      end

      it "includes merged pull requests in the recent activity stream" do
        merged_pr = create(:issue, :pull_request, project: project,
          pr_review_phase: "merged",
          github_number: 1234,
          title: "Ship the thing",
          github_updated_at: 3.minutes.ago)

        get dashboard_path

        expect(response.body).to include("PR ##{merged_pr.github_number}")
        expect(response.body).to include("Ship the thing")
        expect(response.body).to include("Merged")
      end

      it "includes quality pause events in the recent activity stream" do
        create(:quality_pause_event, :paused, project: project,
          composite_score: 0.32,
          threshold: 0.5,
          created_at: 10.minutes.ago)
        create(:quality_pause_event, :resumed, project: project,
          metadata: { resumed_by_user_email: "operator@example.com" },
          created_at: 5.minutes.ago)

        get dashboard_path

        expect(response.body).to include("Automatic work paused by quality gate")
        expect(response.body).to include("32.0% below 50.0%")
        expect(response.body).to include("Quality pause resumed")
        expect(response.body).to include("operator@example.com")
      end

      it "has collapsible sections" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)
        details_elements = doc.css("details")

        expect(details_elements.length).to eq(4)
      end

      it "collapses recent activity by default" do
        get dashboard_path

        doc = Nokogiri::HTML(response.body)

        live_metrics = doc.at_xpath("//details[summary[contains(text(), 'Live Metrics')]]")
        cumulative = doc.at_xpath("//details[summary[contains(text(), 'Cumulative')]]")
        performance = doc.at_xpath("//details[summary[contains(text(), 'Performance')]]")
        recent_activity = doc.at_xpath("//details[summary[contains(text(), 'Recent Activity')]]")

        expect(live_metrics).to be_present
        expect(cumulative).to be_present
        expect(performance).to be_present
        expect(recent_activity).to be_present

        # First three sections should be open (boolean attribute present)
        expect(live_metrics.has_attribute?("open")).to be true
        expect(cumulative.has_attribute?("open")).to be true
        expect(performance.has_attribute?("open")).to be true
        # Recent Activity should be collapsed (no open attribute)
        expect(recent_activity.has_attribute?("open")).to be false
      end
    end
  end

  describe "GET /dashboard/metrics" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "returns metrics partial within a turbo frame" do
      get dashboard_metrics_path(time_range: "7d")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-metrics")
      expect(response.body).to include("Run Volume")
    end

    it "renders the phase breakdown, chart, and knowledge widget inside the frame" do
      project = create(:project, account: account)
      create(:agent_run, :completed, project: project, created_at: 1.day.ago)
      create(:agent_run, :failed, project: project, created_at: 1.day.ago)

      get dashboard_metrics_path(time_range: "7d")

      doc = Nokogiri::HTML(response.body)
      chart = doc.at_css("div#daily-runs-chart")

      expect(response.body).to include("Agent Runs per Day")
      expect(response.body).to include("Run Phase Breakdown")
      expect(chart).to be_present
    end

    it "renders Stimulus-backed chart containers for deferred frame charts", :aggregate_failures do
      project = create(:project, account: account)
      create(:agent_run, :completed, project: project, created_at: 1.day.ago)

      get dashboard_metrics_path(time_range: "7d")

      doc = Nokogiri::HTML(response.body)
      chart = doc.at_css("div#daily-runs-chart[data-controller~='chartkick']")

      expect(chart).to be_present
      expect(chart["data-chartkick-type-value"]).to eq("ColumnChart")
      expect(chart["data-chartkick-options-value"]).to include("\"stacked\":true")
      expect(chart["data-chartkick-data-value"]).to be_present
      expect(chart.text).to include("Loading...")
      expect(doc.css("script")).to be_empty
    end

    it "defaults to cumulative when time_range is invalid" do
      get dashboard_metrics_path(time_range: "invalid")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-metrics")
    end
  end

  describe "GET /dashboard/performance" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "returns performance partial within a turbo frame" do
      get dashboard_performance_path(status: "all", goal: "all")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-performance")
      expect(response.body).to include("Performance by Outcome")
    end

    it "accepts status and goal filters" do
      get dashboard_performance_path(status: "completed", goal: "create_pr")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-performance")
    end

    it "defaults invalid filters to all" do
      get dashboard_performance_path(status: "invalid", goal: "invalid")

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /dashboard/knowledge_stats" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "returns knowledge stats partial within a turbo frame" do
      get dashboard_knowledge_stats_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-knowledge-stats")
      expect(response.body).to include("Knowledge Base")
    end
  end

  describe "GET /dashboard/eligibility_breakdown" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true) }

    before { sign_in user }

    it "returns the eligibility breakdown partial within a turbo frame" do
      create(:issue, project: project, github_state: "open", paid_state: "new")

      get dashboard_eligibility_breakdown_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-eligibility-breakdown")
      expect(response.body).to include("Auto-Pick Eligibility")
      expect(response.body).to include(project.full_name)
    end

    it "links the needs-input count to the dashboard queue" do
      create(:issue, :needs_input, project: project)

      get dashboard_eligibility_breakdown_path

      document = Nokogiri::HTML(response.body)
      link = document.at_css(%(a[href="#{dashboard_needs_input_path(project_id: project.id)}"]))

      expect(link).to be_present
      expect(link.text).to include("1 needs input")
    end
  end

  describe "GET /dashboard/needs_input" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true, owner: "acme", repo: "alpha") }
    let(:second_project) { create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true, owner: "acme", repo: "beta") }
    let(:questions_body) do
      <<~BODY
        <!-- paid:enhance-issue -->

        ## Clarifying questions
        1. What is the expected behavior?
        2. Should this be behind a flag?
      BODY
    end

    before { sign_in user }

    it "lists needs-input issues across auto-pick projects" do
      create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
      create(:issue, :needs_input, project: second_project, title: "Beta question", body: questions_body)
      create(:issue, :closed, :needs_input, project: project, title: "Closed question", body: questions_body)
      create(:issue, :pull_request, :needs_input, project: project, title: "PR question", body: questions_body)

      get dashboard_needs_input_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Needs Input Queue")
      expect(response.body).to include(project.full_name)
      expect(response.body).to include(second_project.full_name)
      expect(response.body).to include("Alpha question")
      expect(response.body).to include("Beta question")
      expect(response.body).to include("What is the expected behavior?")
      expect(response.body).not_to include("Closed question")
      expect(response.body).not_to include("PR question")
    end

    it "supports project scoping" do
      create(:issue, :needs_input, project: project, title: "Alpha question", body: questions_body)
      create(:issue, :needs_input, project: second_project, title: "Beta question", body: questions_body)

      get dashboard_needs_input_path(project_id: project.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(project.full_name)
      expect(response.body).to include("Alpha question")
      expect(response.body).not_to include(second_project.full_name)
      expect(response.body).not_to include("Beta question")
      document = Nokogiri::HTML(response.body)
      link = document.at_css("a[href*='#{project_issue_clarifying_questions_path(project, project.issues.find_by!(title: "Alpha question"))}']")

      expect(link).to be_present
      expect(link["href"]).to eq(
        project_issue_clarifying_questions_path(
          project,
          project.issues.find_by!(title: "Alpha question"),
          queue: "dashboard_needs_input",
          queue_project_id: project.id,
          return_to: dashboard_needs_input_path(project_id: project.id)
        )
      )
    end
  end

  describe "GET /dashboard/decision_metrics" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, name: "Alpha", owner: "acme", repo: "alpha") }

    before { sign_in user }

    def create_decision_metric(project:, created_at:, decision_status: "applied", decision_type: "retry", actor: "timeout_auto_retry", agent_run_traits: [ :completed ])
      create(:orchestration_decision,
        project: project,
        agent_run: create(:agent_run, *agent_run_traits, project: project),
        decision_type: decision_type,
        actor: actor,
        context: { decision_status: decision_status },
        created_at: created_at)
    end

    def create_external_decision_metric(created_at:)
      create(:orchestration_decision, :without_agent_run,
        project: create(:project, name: "Ignored", owner: "ignored", repo: "ignored"),
        decision_type: "retry",
        actor: "timeout_auto_retry",
        context: { decision_status: "applied" },
        created_at: created_at)
    end

    def create_out_of_window_decision_metric(project:, created_at:)
      create_decision_metric(
        project: project,
        created_at: created_at,
        decision_type: "planning_outcome",
        actor: "Workflows::PlanningWorkflow"
      )
    end

    it "returns the orchestration decision metrics partial within a turbo frame" do
      create_decision_metric(project: project, created_at: Time.current)

      get dashboard_decision_metrics_path(time_range: "cumulative")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-decision-metrics")
      expect(response.body).to include("Orchestration Decision Metrics")
      expect(response.body).to include("Decision Types by Context")
      expect(response.body).to include("Outcomes by Decision Type")
      expect(response.body).to include("Recorded Decision Statuses")
      expect(response.body).to include("Decision Actors")
    end

    it "shows an empty state when no orchestration decisions exist" do
      get dashboard_decision_metrics_path(time_range: "cumulative")

      expect(response.body).to include("No orchestration decisions yet")
      expect(response.body).to include("Decision metrics will appear after workflows, retries, and agent selection paths emit orchestration events.")
    end

    it "shows a low-data message when the sample is too small for stable comparisons" do
      create_decision_metric(project: project, created_at: 1.day.ago)

      get dashboard_decision_metrics_path(time_range: "7d")

      expect(response.body).to include("Treat trend and context comparisons as directional until more data arrives.")
      expect(response.body).to include("Only 1 orchestration decision across 1 project match this window.")
      expect(response.body).to include("Not enough daily history yet for a useful trend view.")
    end

    it "scopes decision metrics to the current account and time window" do
      create_decision_metric(project: project, created_at: 2.days.ago)
      create_decision_metric(project: project, created_at: 1.day.ago, decision_status: "failed", agent_run_traits: [ :failed ])
      create_external_decision_metric(created_at: 1.day.ago)
      create_out_of_window_decision_metric(project: project, created_at: 45.days.ago)

      get dashboard_decision_metrics_path(time_range: "7d")

      document = Nokogiri::HTML(response.body)
      actor_headers = document.css("table thead th").map { |header| header.text.squish }

      expect(response.body).to include("Total Decisions")
      expect(response.body).to include("Retry")
      expect(response.body).to include("Alpha")
      expect(response.body).to include("timeout_auto_retry")
      expect(actor_headers).to include("Actor")
      expect(actor_headers).to include("Successful")
      expect(actor_headers).to include("Failed")
      expect(response.body).not_to include("Ignored")
      expect(response.body).not_to include("Planning Outcome")
    end

    it "renders the decision volume chart with Chartkick Stimulus wiring" do
      create_decision_metric(project: project, created_at: 2.days.ago)
      create_decision_metric(project: project, created_at: 1.day.ago, decision_status: "failed", agent_run_traits: [ :failed ])

      get dashboard_decision_metrics_path(time_range: "7d")

      doc = Nokogiri::HTML(response.body)
      chart = doc.at_css("div#decision-volume-chart[data-controller~='chartkick']")

      expect(chart).to be_present
      expect(chart["data-chartkick-type-value"]).to eq("ColumnChart")
      expect(doc.css("script")).to be_empty
    end
  end

  describe "GET /dashboard/pr_cycle_time" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:pr_cycle_time_data) do
      {
        series: [
          { name: "Average", data: { Date.current => 6.0 } },
          { name: "Median (p50)", data: { Date.current => 6.0 } },
          { name: "Trend", data: { Date.current => 6.0 } }
        ],
        outlier_annotations: { Date.current => 1 },
        merged_counts: { Date.current => 1 },
        summary: {
          total_merged: 1,
          total_days: 1,
          overall_avg_hours: 6.0,
          overall_p50_hours: 6.0
        }
      }
    end

    before { sign_in user }

    it "renders the cycle time chart with Chartkick Stimulus wiring" do
      allow(Dashboard::PrCycleTimeSeries).to receive(:call).and_return(pr_cycle_time_data)

      get dashboard_pr_cycle_time_path(time_range: "7d")

      doc = Nokogiri::HTML(response.body)
      chart = doc.at_css("div#pr-cycle-time-chart[data-controller~='chartkick']")

      expect(chart).to be_present
      expect(chart["data-chartkick-type-value"]).to eq("LineChart")
      expect(chart["data-chartkick-options-value"]).to include("\"annotation\"")
      expect(doc.css("script")).to be_empty
    end
  end

  describe "GET /dashboard/queue_health" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "returns queue health partial within a turbo frame" do
      get dashboard_queue_health_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-queue-health")
      expect(response.body).to include("Queue Health")
    end

    it "uses the cached queue health snapshot for the current account" do
      queue_health = instance_double(
        Scaling::QueueMonitor::Result,
        queue_depths: [],
        healthy?: true
      )
      allow(Scaling::QueueMonitor).to receive(:cached_for_account).with(account).and_return(queue_health)

      get dashboard_queue_health_path

      expect(Scaling::QueueMonitor).to have_received(:cached_for_account).with(account)
    end
  end

  describe "GET /dashboard/runner_health" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "returns runner health partial within a turbo frame" do
      runner = user.runners.find_by!(runner_key: Runner.default_runner_key, auth_type: "subscription")
      create(:runner_state, :rate_limited, user: user, runner_name: runner.state_key)

      get dashboard_runner_health_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-runner-health")
      expect(response.body).to include("Runner Health")
      expect(response.body).to include(runner.display_name)
      expect(response.body).to include("Rate limited")
      expect(response.body).to include("Configured")
    end

    it "uses plural grammar for multiple recovering runners" do
      create(:user_setting, user: user, circuit_breaker_timeout_seconds: 30)
      first_provider = user.runners.find_by!(runner_key: Runner.default_runner_key, auth_type: "subscription")
      second_provider_key = (RunnerSupport.container_executable_runner_keys - [ first_provider.runner_key ]).first || "cursor"
      second_provider = create(:runner, user: user, runner_key: second_provider_key, auth_type: "subscription")

      [ first_provider, second_provider ].each do |runner|
        create(
          :provider_state,
          :circuit_open,
          user: user,
          runner_name: runner.state_key,
          circuit_opened_at: 31.seconds.ago
        )
      end

      get dashboard_runner_health_path

      expect(response.body).to include("2 runners are recovering in half-open mode.")
    end

    it "shows free-model availability details for openrouter_free" do
      free_model = create(:llm_model, model_id: "high-free", provider: "openrouter", tier: "high", pricing_tier: "free")
      create(:llm_model, model_id: "mid-free", provider: "openrouter", tier: "mid", pricing_tier: "free")
      api_key = create(:provider_api_key, user: user, api_service_type: "openrouter")
      runner = create(
        :runner,
        user: user,
        runner_key: "openrouter_free",
        auth_type: "api_key",
        provider_api_key: api_key,
        tier_model_ids: LlmModel::TIERS.index_with { free_model.model_id }
      )
      create(:runner_state, user: user, runner_name: "#{runner.state_key}:#{free_model.model_id}", rate_limited_until: 10.minutes.from_now)

      get dashboard_runner_health_path

      expect(response.body).to include("1 of 2 free models available")
      expect(response.body).to include("Add OpenRouter credits")
    end
  end

  describe "GET /dashboard/github_health" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    before { sign_in user }

    it "returns github credential health partial within a turbo frame" do
      get dashboard_github_health_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("dashboard-github-health")
      expect(response.body).to include("GitHub Credential Health")
    end

    it "renders per-installation rate-limit usage for app-backed projects" do
      installation = create(:github_installation, account: account, account_login: "my-org")
      create(:project, :with_github_installation, account: account, github_installation: installation)
      create(
        :github_health_state,
        endpoint: GithubHealthState.endpoint_for_github_installation(installation.github_installation_id),
        rate_limit_remaining: 3000,
        rate_limit_limit: 15_000,
        rate_limit_reset_at: 1.hour.from_now,
        rate_limit_observed_at: 1.minute.ago
      )

      get dashboard_github_health_path

      expect(response.body).to include("my-org")
      expect(response.body).to include("App")
      expect(response.body).to include("15,000/hr")
    end
  end

  describe "GET /dashboard/queue_preview" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user) }

    before { sign_in user }

    it "renders the queue preview inside the dashboard frame" do
      create(:agent_run, :queued, project: project)

      get dashboard_queue_preview_path

      expect(response).to have_http_status(:ok)

      doc = Nokogiri::HTML.fragment(response.body)
      frame = doc.at_css("turbo-frame#dashboard-queue-preview")

      expect(frame).to be_present
      expect(frame["src"]).to be_nil
      expect(frame.to_html).to include("Upcoming Queue")
    end
  end

  describe "GET /dashboard/live" do
    it "redirects to the dashboard" do
      get dashboard_live_path
      expect(response).to redirect_to(dashboard_path)
    end
  end

  describe "POST /dashboard/cancel_run/:id" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user) }

    before { sign_in user }

    it "cancels an active run and enqueues background cleanup" do
      agent_run = create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago)

      expect {
        post dashboard_cancel_run_path(agent_run)
      }.to have_enqueued_job(AgentRunCancellationJob).with(agent_run.id)

      expect(response).to redirect_to(dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(agent_run.reload.status).to eq("cancelled")
    end

    it "returns not found for a run in another account" do
      other_run = create(:agent_run, status: "running", started_at: 1.minute.ago)

      post dashboard_cancel_run_path(other_run)

      expect(response).to have_http_status(:not_found)
    end

    it "redirects when the run is already finished" do
      agent_run = create(:agent_run, project: project, status: "completed", completed_at: Time.current)

      post dashboard_cancel_run_path(agent_run)

      expect(response).to redirect_to(dashboard_path)
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("Agent run is no longer active.")
    end

    it "bumps the queue preview cache version for queue-preview HTML fallback requests" do
      agent_run = create(:agent_run, :queued, project: project)

      allow(Dashboard::CacheVersion).to receive(:bump).and_call_original

      post dashboard_cancel_run_path(agent_run), params: { source: "queue_preview" }

      expect(response).to redirect_to(dashboard_path)
      expect(Dashboard::CacheVersion).to have_received(:bump).with(
        account,
        scope: Dashboard::CacheVersion::LISTS_SCOPE
      )
    end

    context "with a Turbo Stream request" do
      it "removes the dashboard row after cancellation" do
        agent_run = create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago)

        post dashboard_cancel_run_path(agent_run), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include(%(action="remove" target="dashboard_row_agent_run_#{agent_run.id}"))
        expect(agent_run.reload.status).to eq("cancelled")
      end

      it "removes a queued run row from the upcoming queue" do
        agent_run = create(:agent_run, :queued, project: project)

        post dashboard_cancel_run_path(agent_run), params: { source: "queue_preview" }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(action="replace" target="queue-preview"))
        expect(response.body).to include("No queued runs for your projects.")
        expect(agent_run.reload.status).to eq("cancelled")
      end

      it "re-renders the upcoming queue with refreshed positions after cancelling a queued run" do
        first_run = create(:agent_run, :queued, project: project, created_at: 3.minutes.ago)
        second_run = create(:agent_run, :queued, project: project, created_at: 2.minutes.ago)
        third_run = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

        post dashboard_cancel_run_path(first_run), params: { source: "queue_preview" }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(action="replace" target="queue-preview"))
        expect(response.body).not_to include(%(queue_preview_row_agent_run_#{first_run.id}))
        expect(agent_run_rows_in_queue_preview(response.body).pluck(:id)).to contain_exactly(second_run.id, third_run.id)
        expect(agent_run_rows_in_queue_preview(response.body).pluck(:position)).to eq([ 1, 2 ])
        expect(first_run.reload.status).to eq("cancelled")
      end

      it "refreshes the queue preview when the cancel request originated there, even if the run is now running" do
        agent_run = create(:agent_run, :queued, project: project)
        agent_run.update!(status: "running", started_at: Time.current)

        post dashboard_cancel_run_path(agent_run), params: { source: "queue_preview" }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(action="replace" target="queue-preview"))
        expect(response.body).not_to include(%(action="remove" target="dashboard_row_agent_run_#{agent_run.id}"))
        expect(agent_run.reload.status).to eq("cancelled")
      end

      it "prepends an alert when the run is no longer active" do
        agent_run = create(:agent_run, project: project, status: "completed", completed_at: Time.current)

        post dashboard_cancel_run_path(agent_run), as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(action="prepend" target="dashboard-alerts"))
        expect(response.body).to include("Agent run is no longer active.")
      end

      it "refreshes the queue preview and prepends an alert when the run is no longer active" do
        agent_run = create(:agent_run, :queued, project: project)
        agent_run.update!(status: "completed", completed_at: Time.current)

        post dashboard_cancel_run_path(agent_run), params: { source: "queue_preview" }, as: :turbo_stream

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(action="replace" target="queue-preview"))
        expect(response.body).to include(%(action="prepend" target="dashboard-alerts"))
        expect(response.body).to include("Agent run is no longer active.")
        expect(response.body).to include("No queued runs for your projects.")
        expect(response.body).not_to include(%(queue_preview_row_agent_run_#{agent_run.id}))
      end

      it "forbids users who cannot run agents" do
        account_membership = user.account_membership_for(account)
        account_membership.update!(role: :viewer)
        agent_run = create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago)

        post dashboard_cancel_run_path(agent_run), as: :turbo_stream

        expect(response).to redirect_to(root_path)
        expect(response).to have_http_status(:found)
      end
    end
  end

  def agent_run_rows_in_queue_preview(turbo_stream_body)
    fragment = Nokogiri::HTML.fragment(turbo_stream_body)
    template = fragment.at_css('turbo-stream[action="replace"][target="queue-preview"] template')
    return [] if template.nil?

    queue_preview = Nokogiri::HTML.fragment(CGI.unescapeHTML(template.inner_html))

    queue_preview.css("tr[id^='queue_preview_row_agent_run_']").map do |row|
      {
        id: row["id"].delete_prefix("queue_preview_row_agent_run_").to_i,
        position: row.at_css("td")&.text&.strip&.to_i
      }
    end
  end
end
