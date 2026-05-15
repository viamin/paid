# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::PrTemplates" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe "GET /projects/:project_id/pr_templates" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get project_pr_templates_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists project-level PR templates" do
        create(:pr_template, account: account, project: project, name: "standard")
        get project_pr_templates_path(project)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "POST /projects/:project_id/pr_templates" do
    let(:valid_params) do
      {
        pr_template: {
          name: "standard", pr_type: "default",
          body: "## Summary\n\n{{description}}", position: 0
        }
      }
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "creates a project-level PR template" do
        existing_ids = PrTemplate.pluck(:id)

        expect {
          post project_pr_templates_path(project), params: valid_params
        }.to change(PrTemplate, :count).by(1)

        expect(response).to have_http_status(:created)
        template = PrTemplate.where.not(id: existing_ids).sole
        expect(template.name).to eq("standard")
        expect(template.project).to eq(project)
        expect(template.account).to eq(account)
        expect(template).to be_project_level
      end
    end
  end

  describe "PATCH /projects/:project_id/pr_templates/:id" do
    let!(:pr_template) do
      create(:pr_template, account: account, project: project, name: "standard")
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "updates the template" do
        patch project_pr_template_path(project, pr_template),
          params: { pr_template: { name: "updated-standard" } }

        expect(response).to have_http_status(:ok)
        expect(pr_template.reload.name).to eq("updated-standard")
      end
    end
  end

  describe "DELETE /projects/:project_id/pr_templates/:id" do
    let!(:pr_template) do
      create(:pr_template, account: account, project: project, name: "standard")
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "destroys the template" do
        expect {
          delete project_pr_template_path(project, pr_template)
        }.to change(PrTemplate, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end
    end
  end
end
