# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe "Projects::ServiceContainers" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "POST /projects/:project_id/project_service_containers" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        sc = create(:service_container, account: account)
        post project_project_service_containers_path(project), params: { service_container_id: sc.id }
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "associates a service container with the project" do
        sc = create(:service_container, account: account)
        expect {
          post project_project_service_containers_path(project), params: { service_container_id: sc.id }
        }.to change(ProjectServiceContainer, :count).by(1)
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to include("added")
      end

      it "does not create duplicate associations" do
        sc = create(:service_container, account: account)
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

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before { sign_in member }

      it "redirects with authorization error" do
        sc = create(:service_container, account: account)
        post project_project_service_containers_path(project), params: { service_container_id: sc.id }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "redirects with authorization error" do
        sc = create(:service_container, account: account)
        post project_project_service_containers_path(project), params: { service_container_id: sc.id }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "readiness repair" do
    let(:checkout_path) { Pathname.new(Dir.mktmpdir) }

    before do
      FileUtils.mkdir_p(checkout_path.join(".paid"))
      FileUtils.mkdir_p(checkout_path.join("bin"))
      File.write(checkout_path.join(".paid/screenshots.yml"), <<~YAML)
        routes:
          - path: /
            name: Home
        services: #{[ "postgres" ].to_json}
      YAML
      File.write(checkout_path.join("bin/dev"), "#!/bin/sh\n")
    end

    after { FileUtils.remove_entry(checkout_path) }

    def verification_project
      create(:project, account: account, github_token: github_token, created_by: user, tdd_mode: "off",
        screenshot_settings: { "verification_enabled" => true })
    end

    def setup_pending_entries
      Inbox::Queue.call(user:, kind: Inbox::Queue::PROJECT_SETUP_PENDING_KIND)
    end

    # @spec PROJECT-READINESS-006, PROJECT-READINESS-011
    it "re-evaluates readiness after the missing verification service is associated" do
      sign_in user
      service = create(:service_container, account: account, name: "postgres")
      project = verification_project

      Projects::Readiness::Record.call(project:, repo_path: checkout_path)
      expect(project.reload.readiness_gaps.map { |gap| gap["kind"] }).to eq([ "missing_verification_service" ])
      expect(setup_pending_entries.map(&:project)).to eq([ project ])

      expect {
        post project_project_service_containers_path(project), params: { service_container_id: service.id }
      }.to have_enqueued_job(EvaluateProjectReadinessJob).with(project.id)

      Projects::Readiness::Record.call(project:, repo_path: checkout_path)
      expect(project.reload.readiness_gaps).to be_empty
      expect(setup_pending_entries).to be_empty
    end

    it "re-evaluates readiness after a service association is removed" do
      sign_in user
      service = create(:service_container, account: account, name: "postgres")
      project = verification_project
      association = create(:project_service_container, project: project, service_container: service)

      expect {
        delete project_project_service_container_path(project, association)
      }.to have_enqueued_job(EvaluateProjectReadinessJob).with(project.id)
    end
  end

  describe "DELETE /projects/:project_id/project_service_containers/:id" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        sc = create(:service_container, account: account)
        psc = create(:project_service_container, project: project, service_container: sc)
        delete project_project_service_container_path(project, psc)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "removes the service container from the project" do
        sc = create(:service_container, account: account)
        psc = create(:project_service_container, project: project, service_container: sc)
        expect {
          delete project_project_service_container_path(project, psc)
        }.to change(ProjectServiceContainer, :count).by(-1)
        expect(response).to redirect_to(edit_project_path(project))
        expect(flash[:notice]).to include("removed")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before { sign_in member }

      it "redirects with authorization error" do
        sc = create(:service_container, account: account)
        psc = create(:project_service_container, project: project, service_container: sc)
        delete project_project_service_container_path(project, psc)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "redirects with authorization error" do
        sc = create(:service_container, account: account)
        psc = create(:project_service_container, project: project, service_container: sc)
        delete project_project_service_container_path(project, psc)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end
end
