# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ServiceContainers" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before do
    user.add_role(:admin, account)
  end

  describe "GET /service_containers" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get service_containers_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before { sign_in user }

      it "renders the index page" do
        get service_containers_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Service Containers")
      end

      it "shows existing service containers" do
        sc = create(:service_container, name: "test-postgres")
        get service_containers_path
        expect(response.body).to include("test-postgres")
        expect(response.body).to include(sc.image)
      end

      it "shows empty state when no service containers exist" do
        get service_containers_path
        expect(response.body).to include("No service containers")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before { sign_in viewer }

      it "redirects with authorization error" do
        get service_containers_path
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "GET /service_containers/new" do
    context "when authenticated as admin" do
      before { sign_in user }

      it "renders the new form" do
        get new_service_container_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("New Service Container")
      end
    end
  end

  describe "POST /service_containers" do
    before { sign_in user }

    let(:valid_params) do
      {
        service_container: {
          name: "my-postgres",
          image: "postgres:16",
          port: 5432,
          env_json: '{"POSTGRES_USER": "agent"}'
        }
      }
    end

    context "with valid parameters" do
      it "creates a new service container" do
        expect {
          post service_containers_path, params: valid_params
        }.to change(ServiceContainer, :count).by(1)
      end

      it "redirects to the show page with success message" do
        post service_containers_path, params: valid_params
        expect(response).to redirect_to(service_container_path(ServiceContainer.last))
        expect(flash[:notice]).to include("successfully created")
      end

      it "sets status to stopped" do
        post service_containers_path, params: valid_params
        expect(ServiceContainer.last.status).to eq("stopped")
      end

      it "stores the env as parsed JSON" do
        post service_containers_path, params: valid_params
        expect(ServiceContainer.last.env).to eq({ "POSTGRES_USER" => "agent" })
      end
    end

    context "with invalid parameters" do
      it "re-renders the form when name is missing" do
        post service_containers_path, params: { service_container: { name: "", image: "postgres:16", port: 5432 } }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "re-renders the form when port is invalid" do
        post service_containers_path, params: { service_container: { name: "test", image: "postgres:16", port: 0 } }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "GET /service_containers/:id" do
    before { sign_in user }

    it "shows the service container details" do
      sc = create(:service_container, name: "my-pg")
      get service_container_path(sc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("my-pg")
      expect(response.body).to include(sc.image)
    end
  end

  describe "GET /service_containers/:id/edit" do
    before { sign_in user }

    it "shows the edit form" do
      sc = create(:service_container, name: "my-pg")
      get edit_service_container_path(sc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Edit Service Container")
      expect(response.body).to include("my-pg")
    end
  end

  describe "PATCH /service_containers/:id" do
    before { sign_in user }

    it "updates the service container" do
      sc = create(:service_container, name: "old-name")
      patch service_container_path(sc), params: { service_container: { name: "new-name" } }
      expect(sc.reload.name).to eq("new-name")
      expect(response).to redirect_to(service_container_path(sc))
      expect(flash[:notice]).to include("successfully updated")
    end

    it "re-renders the form on validation error" do
      sc = create(:service_container)
      patch service_container_path(sc), params: { service_container: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /service_containers/:id" do
    context "when user is owner" do
      before do
        user.add_role(:owner, account)
        sign_in user
      end

      it "deletes the service container" do
        sc = create(:service_container)
        expect {
          delete service_container_path(sc)
        }.to change(ServiceContainer, :count).by(-1)
      end

      it "redirects with success message" do
        sc = create(:service_container)
        delete service_container_path(sc)
        expect(response).to redirect_to(service_containers_path)
        expect(flash[:notice]).to include("successfully deleted")
      end
    end

    context "when user is admin (not owner)" do
      it "does not allow deletion" do
        sc = create(:service_container)
        sign_in user
        delete service_container_path(sc)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end
end
