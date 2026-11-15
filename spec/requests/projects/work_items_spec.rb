# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects work-item integration" do
  include_context "with stable agent run request project"

  let(:work_item) { create(:work_item, account: account, title: "Linear ticket title") }

  before { account.tenant_setting!.update!(features: { "unified_work_items" => true }) }

  describe "GET /projects/:project_id/work_items" do
    before { sign_in user }

    it "lists work items assigned to the project" do
      # @spec UNIFIED-WORK-ITEMS-004
      create(:work_item_assignment, account: account, work_item: work_item, project: project)
      create(:work_item, account: account, title: "Unrelated ticket")

      get project_work_items_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Linear ticket title")
      expect(response.body).not_to include("Unrelated ticket")
    end

    it "returns not found while the rollout guard is disabled" do
      # @spec UNIFIED-WORK-ITEMS-009
      account.tenant_setting!.update!(features: { "unified_work_items" => false })

      get project_work_items_path(project)

      expect(response).to have_http_status(:not_found)
    end

    it "paginates the panel instead of materializing every assigned ticket" do
      # @spec UNIFIED-WORK-ITEMS-004
      create_list(:work_item, 26, account: account) do |item, index|
        item.update!(title: format("Panel ticket %02d", index), created_at: index.hours.ago)
        create(:work_item_assignment, account: account, work_item: item, project: project)
      end

      get project_work_items_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Panel ticket 00")
      expect(response.body).not_to include("Panel ticket 25")
      expect(response.body).to include("Next")

      get project_work_items_path(project, page: 2)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Panel ticket 25")
      expect(response.body).not_to include("Panel ticket 00")
    end

    it "batches assignment loading for the page" do
      # @spec UNIFIED-WORK-ITEMS-004
      5.times do
        item = create(:work_item, account: account)
        create(:work_item_assignment, account: account, work_item: item, project: project)
      end

      queries = capture_queries { get project_work_items_path(project) }

      expect(queries.count { |sql| sql.include?('FROM "work_item_assignments"') }).to be <= 2
    end
  end

  describe "POST /projects/:project_id/work_items/:id/set_default_execution" do
    before { sign_in user }

    it "sets the issue-level default execution project" do
      # @spec UNIFIED-WORK-ITEMS-004
      create(:work_item_assignment, account: account, work_item: work_item, project: project)

      post set_default_execution_project_work_item_path(project, work_item),
        params: { target_project_id: project.id }

      expect(work_item.work_item_assignments.find_by(project: project).reload.default_execution).to be(true)
      expect(response).to redirect_to(project_work_items_path(project))
    end

    it "denies a plain account member" do
      member = create(:user, :member, account: account)
      sign_out :user
      sign_in member
      create(:work_item_assignment, account: account, work_item: work_item, project: project)

      post set_default_execution_project_work_item_path(project, work_item),
        params: { target_project_id: project.id }

      expect(work_item.work_item_assignments.find_by(project: project).reload.default_execution).to be(false)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /projects/:project_id/agent_runs/new with a work item" do
    before { sign_in user }

    it "prefills the form from the ticket" do
      # @spec UNIFIED-WORK-ITEMS-005
      create(:work_item_assignment, account: account, work_item: work_item, project: project)

      get new_project_agent_run_path(project, goal: "create_pr", work_item_id: work_item.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Linear ticket title")
      expect(response.body).to include(%(name="work_item_id"))
      expect(response.body).to include(%(value="#{work_item.id}"))
    end

    it "ignores the work item while the rollout guard is disabled" do
      # @spec UNIFIED-WORK-ITEMS-009
      account.tenant_setting!.update!(features: { "unified_work_items" => false })
      create(:work_item_assignment, account: account, work_item: work_item, project: project)

      get new_project_agent_run_path(project, goal: "create_pr", work_item_id: work_item.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(%(name="work_item_id"))
    end

    it "ignores a work item assigned to a different project" do
      other_project = create(:project, account: account)
      create(:work_item_assignment, account: account, work_item: work_item, project: other_project)

      get new_project_agent_run_path(project, goal: "create_pr", work_item_id: work_item.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(%(name="work_item_id"))
    end

    it "ignores a GitHub-provider work item so its untrusted content cannot prefill the form" do
      # @spec UNIFIED-WORK-ITEMS-005
      github_item = create(:work_item, account: account, provider: "github", title: "Untrusted GitHub title")
      create(:work_item_assignment, account: account, work_item: github_item, project: project)

      get new_project_agent_run_path(project, goal: "create_pr", work_item_id: github_item.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(%(name="work_item_id"))
      expect(response.body).not_to include("Untrusted GitHub title")
    end
  end

  describe "POST /projects/:project_id/agent_runs with a work item" do
    before { sign_in user }

    it "creates a queued run linked to the work item with the composed prompt" do
      # @spec UNIFIED-WORK-ITEMS-005
      create(:work_item_assignment, account: account, work_item: work_item, project: project)

      expect {
        post project_agent_runs_path(project), params: { work_item_id: work_item.id }
      }.to change(AgentRun, :count).by(1)

      agent_run = AgentRun.last
      expect(agent_run.work_item).to eq(work_item)
      expect(agent_run.project).to eq(project)
      expect(agent_run.custom_prompt).to include("Linear ticket title")
      expect(agent_run.status).to eq("queued")
    end

    it "keeps an explicit custom prompt" do
      create(:work_item_assignment, account: account, work_item: work_item, project: project)

      post project_agent_runs_path(project), params: { work_item_id: work_item.id, custom_prompt: "Hand written" }

      expect(AgentRun.last.custom_prompt).to include("Hand written")
    end

    it "preserves run authorization" do
      # @spec UNIFIED-WORK-ITEMS-005
      plain_user = create(:user, account: account)
      sign_out :user
      sign_in plain_user
      create(:work_item_assignment, account: account, work_item: work_item, project: project)

      expect {
        post project_agent_runs_path(project), params: { work_item_id: work_item.id }
      }.not_to change(AgentRun, :count)

      expect(response).to redirect_to(root_path)
    end

    it "falls back to the existing source guard while the rollout guard is disabled" do
      # @spec UNIFIED-WORK-ITEMS-009
      account.tenant_setting!.update!(features: { "unified_work_items" => false })
      create(:work_item_assignment, account: account, work_item: work_item, project: project)

      expect {
        post project_agent_runs_path(project), params: { work_item_id: work_item.id }
      }.not_to change(AgentRun, :count)

      expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
      expect(flash[:alert]).to include("Please select an issue")
    end

    it "rejects a work item that is not assigned to the project" do
      expect {
        post project_agent_runs_path(project), params: { work_item_id: work_item.id }
      }.not_to change(AgentRun, :count)

      expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
    end

    it "refuses to compose a prompt from a GitHub-provider work item" do
      # @spec UNIFIED-WORK-ITEMS-005
      github_item = create(:work_item, account: account, provider: "github",
        title: "Untrusted GitHub title", body: "Untrusted GitHub body")
      create(:work_item_assignment, account: account, work_item: github_item, project: project)

      expect {
        post project_agent_runs_path(project), params: { work_item_id: github_item.id }
      }.not_to change(AgentRun, :count)

      expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr"))
      expect(flash[:alert]).to include("Please select an issue")
    end
  end
end
