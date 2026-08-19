# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::EgressAllowlistEntries" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }

  describe "GET /projects/:project_id/egress_allowlist_entries" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get project_egress_allowlist_entries_path(project)
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "renders the index page" do
        get project_egress_allowlist_entries_path(project)
        expect(response).to have_http_status(:ok)
      end

      it "lists project-level entries and inherited account-level entries" do
        create(:egress_allowlist_entry, account: account, project: project, host_pattern: "project.example.com")
        create(:egress_allowlist_entry, account: account, host_pattern: "account.example.com")

        get project_egress_allowlist_entries_path(project)

        expect(response.body).to include("project.example.com")
        expect(response.body).to include("account.example.com")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "renders the index page without management controls" do
        create(:egress_allowlist_entry, account: account, project: project, host_pattern: "project.example.com")

        get project_egress_allowlist_entries_path(project)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Add entry")
      end
    end
  end

  describe "POST /projects/:project_id/egress_allowlist_entries" do
    let(:valid_params) do
      { egress_allowlist_entry: { host_pattern: "api.example.com", scheme: "https", reason: "internal API" } }
    end

    context "when not authenticated" do
      it "redirects to the sign in page" do
        post project_egress_allowlist_entries_path(project), params: valid_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "creates a project-level allowlist entry" do
        expect {
          post project_egress_allowlist_entries_path(project), params: valid_params
        }.to change(EgressAllowlistEntry, :count).by(1)

        expect(response).to redirect_to(project_egress_allowlist_entries_path(project))
        entry = project.egress_allowlist_entries.last
        expect(entry.host_pattern).to eq("api.example.com")
        expect(entry.account).to eq(account)
        expect(entry).to be_project_level
      end

      it "records a project activity event" do
        expect {
          post project_egress_allowlist_entries_path(project), params: valid_params
        }.to change(AccountActivityEvent, :count).by(1)

        event = AccountActivityEvent.last
        expect(event.action).to eq("egress_allowlist.project_entry_created")
        expect(event.subject).to eq(project)
      end

      it "re-renders the form with an actionable error on an unsafe host pattern" do
        expect {
          post project_egress_allowlist_entries_path(project),
            params: { egress_allowlist_entry: { host_pattern: "192.0.2.10" } }
        }.not_to change(EgressAllowlistEntry, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("hostname")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        post project_egress_allowlist_entries_path(project), params: valid_params
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "PATCH /projects/:project_id/egress_allowlist_entries/:id" do
    let!(:entry) { create(:egress_allowlist_entry, account: account, project: project, host_pattern: "api.example.com") }

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "toggles the entry's enabled state" do
        patch project_egress_allowlist_entry_path(project, entry),
          params: { egress_allowlist_entry: { enabled: false } }

        expect(response).to redirect_to(project_egress_allowlist_entries_path(project))
        expect(entry.reload).not_to be_enabled
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        patch project_egress_allowlist_entry_path(project, entry),
          params: { egress_allowlist_entry: { enabled: false } }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "DELETE /projects/:project_id/egress_allowlist_entries/:id" do
    let!(:entry) { create(:egress_allowlist_entry, account: account, project: project, host_pattern: "api.example.com") }

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "destroys the entry" do
        expect {
          delete project_egress_allowlist_entry_path(project, entry)
        }.to change(EgressAllowlistEntry, :count).by(-1)

        expect(response).to redirect_to(project_egress_allowlist_entries_path(project))
      end

      it "records a project activity event" do
        expect {
          delete project_egress_allowlist_entry_path(project, entry)
        }.to change(AccountActivityEvent, :count).by(1)

        expect(AccountActivityEvent.last.action).to eq("egress_allowlist.project_entry_removed")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        delete project_egress_allowlist_entry_path(project, entry)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end
end
