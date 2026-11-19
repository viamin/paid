# frozen_string_literal: true

require "rails_helper"

RSpec.describe "WorkItems browser" do
  let(:account) { create(:account) }
  let(:admin) { create(:user, :admin, account:) }
  let(:member) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:work_item) { create(:work_item, :with_native_project, account:) }

  before { account.tenant_setting!.update!(features: { "unified_work_items" => true }) }

  describe "GET /work_items" do
    before { sign_in admin }

    it "lists unassigned work first" do
      # @spec UNIFIED-WORK-ITEMS-004
      assigned = create(:work_item, account:, title: "Assigned ticket")
      create(:work_item_assignment, account:, work_item: assigned, project:)
      unassigned = create(:work_item, account:, title: "Unassigned ticket")

      get work_items_path

      expect(response).to have_http_status(:ok)
      expect(response.body.index("Unassigned ticket")).to be < response.body.index("Assigned ticket")
    end

    it "filters to items needing review" do
      flagged = create(:work_item, account:, title: "Needs review", assignment_review_flagged_at: Time.current)
      create(:work_item, account:, title: "Settled")

      get work_items_path, params: { needing_review: true }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Needs review")
      expect(response.body).not_to include("Settled")
    end

    it "returns not found while the rollout guard is disabled" do
      # @spec UNIFIED-WORK-ITEMS-009
      account.tenant_setting!.update!(features: { "unified_work_items" => false })

      get work_items_path

      expect(response).to have_http_status(:not_found)
    end

    it "paginates the listing instead of materializing the backlog" do
      # @spec UNIFIED-WORK-ITEMS-004
      create_list(:work_item, 26, account:) do |item, index|
        item.update!(title: format("Ticket %02d", index), created_at: index.hours.ago)
      end

      get work_items_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ticket 00")
      expect(response.body).not_to include("Ticket 25")
      expect(response.body).to include("Next")

      get work_items_path, params: { page: 2 }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ticket 25")
      expect(response.body).not_to include("Ticket 00")
    end

    it "batches assignment and project loading for the page" do
      # @spec UNIFIED-WORK-ITEMS-004
      5.times do |index|
        item = create(:work_item, account:, title: "Ticket #{index}")
        create(:work_item_assignment, account:, work_item: item, project:)
      end

      queries = capture_queries { get work_items_path }

      expect(queries.count { |sql| sql.include?('FROM "work_item_assignments"') }).to be <= 2
      expect(queries.count { |sql| sql.include?('FROM "projects"') }).to be <= 2
    end
  end

  describe "GET /work_items/:id" do
    before { sign_in admin }

    it "shows assignments and the review flag" do
      create(:work_item_assignment, account:, work_item:, project:)

      get work_item_path(work_item)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(project.name)
    end

    it "returns not found while the rollout guard is disabled" do
      # @spec UNIFIED-WORK-ITEMS-009
      account.tenant_setting!.update!(features: { "unified_work_items" => false })

      get work_item_path(work_item)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /work_items/:id/assign" do
    before { sign_in member }

    it "bulk-assigns the selected projects" do
      # @spec UNIFIED-WORK-ITEMS-004
      other_project = create(:project, account:)

      expect {
        post assign_work_item_path(work_item), params: { project_ids: [ project.id, other_project.id ] }
      }.to change { work_item.work_item_assignments.count }.by(2)

      expect(response).to redirect_to(work_item_path(work_item))
      expect(work_item.projects).to contain_exactly(project, other_project)
    end

    it "ignores projects outside the account" do
      foreign_project = create(:project)

      expect {
        post assign_work_item_path(work_item), params: { project_ids: [ foreign_project.id ] }
      }.not_to change { work_item.work_item_assignments.count }

      expect(response).to redirect_to(work_item_path(work_item))
      expect(flash[:alert]).to include("No assignable project")
    end

    it "ignores a user outside the account" do
      outsider = create(:user)
      sign_out :user
      sign_in outsider

      expect {
        post assign_work_item_path(work_item), params: { project_ids: [ project.id ] }
      }.not_to change { work_item.work_item_assignments.count }
    end
  end

  describe "POST /work_items/bulk_assign" do
    before { sign_in member }

    it "assigns several selected tickets to the selected projects" do
      # @spec UNIFIED-WORK-ITEMS-004
      other_item = create(:work_item, account:)
      other_project = create(:project, account:)

      post bulk_assign_work_items_path,
        params: { work_item_ids: [ work_item.id, other_item.id ], project_ids: [ project.id, other_project.id ] }

      expect(response).to redirect_to(work_items_path)
      expect(work_item.reload.projects).to contain_exactly(project, other_project)
      expect(other_item.reload.projects).to contain_exactly(project, other_project)
    end
  end

  describe "POST /work_items/:id/clear_review_flag" do
    before { work_item.update!(assignment_review_flagged_at: Time.current) }

    it "clears the flag for an account admin" do
      # @spec UNIFIED-WORK-ITEMS-004
      sign_in admin

      post clear_review_flag_work_item_path(work_item)

      expect(work_item.reload.needs_review?).to be(false)
      expect(response).to redirect_to(work_item_path(work_item))
    end

    it "denies an account member" do
      sign_in member

      post clear_review_flag_work_item_path(work_item)

      expect(work_item.reload.needs_review?).to be(true)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /work_items/:id/start_run" do
    before { sign_in admin }

    it "redirects to the resolved default execution project" do
      # @spec UNIFIED-WORK-ITEMS-004
      create(:work_item_assignment, account:, work_item:, project:, default_execution: true)

      get start_run_work_item_path(work_item)

      expect(response).to redirect_to(new_project_agent_run_path(project, goal: "create_pr", work_item_id: work_item.id))
    end

    it "redirects back when the work item has no assigned project" do
      get start_run_work_item_path(work_item)

      expect(response).to redirect_to(work_item_path(work_item))
      expect(flash[:alert]).to include("Assign the ticket to a project")
    end
  end
end
