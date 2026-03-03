# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::ServiceContainers" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "POST /projects/:project_id/project_service_containers" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        sc = create(:service_container)
        post project_project_service_containers_path(project), params: { service_container_id: sc.id }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "associates a service container with the project" do
        sc = create(:service_container)
        expect {
          post project_project_service_containers_path(project), params: { service_container_id: sc.id }
        }.to change(ProjectServiceContainer, :count).by(1)
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to include("added")
      end

      it "does not create duplicate associations" do
        sc = create(:service_container)
        create(:project_service_container, project: project, service_container: sc)
        expect {
          post project_project_service_containers_path(project), params: { service_container_id: sc.id }
        }.not_to change(ProjectServiceContainer, :count)
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:alert]).to include("already associated")
      end

      it "handles non-existent service container" do
        post project_project_service_containers_path(project), params: { service_container_id: 0 }
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:alert]).to include("not found")
      end
    end
  end

  describe "DELETE /projects/:project_id/project_service_containers/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        sc = create(:service_container)
        psc = create(:project_service_container, project: project, service_container: sc)
        delete project_project_service_container_path(project, psc)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "removes the service container from the project" do
        sc = create(:service_container)
        psc = create(:project_service_container, project: project, service_container: sc)
        expect {
          delete project_project_service_container_path(project, psc)
        }.to change(ProjectServiceContainer, :count).by(-1)
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to include("removed")
      end
    end
  end
end
