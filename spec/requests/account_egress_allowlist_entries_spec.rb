# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Accounts::EgressAllowlistEntries" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /account_egress_allowlist_entries" do
    context "when not authenticated" do
      it "redirects to the sign in page" do
        get account_egress_allowlist_entries_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated" do
      before { sign_in user }

      it "lists account-level allowlist entries" do
        create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")
        get account_egress_allowlist_entries_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("api.example.com")
      end
    end
  end

  describe "POST /account_egress_allowlist_entries" do
    let(:valid_params) do
      { egress_allowlist_entry: { host_pattern: "api.example.com", scheme: "https", reason: "package registry" } }
    end

    context "when not authenticated" do
      it "redirects to the sign in page" do
        post account_egress_allowlist_entries_path, params: valid_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "creates an account-wide allowlist entry" do
        expect {
          post account_egress_allowlist_entries_path, params: valid_params
        }.to change(EgressAllowlistEntry, :count).by(1)

        expect(response).to redirect_to(account_egress_allowlist_entries_path)
        entry = EgressAllowlistEntry.last
        expect(entry.host_pattern).to eq("api.example.com")
        expect(entry.account).to eq(account)
        expect(entry).to be_account_level
      end

      it "records an audit event" do
        expect {
          post account_egress_allowlist_entries_path, params: valid_params
        }.to change(AccountActivityEvent, :count).by(1)

        event = AccountActivityEvent.last
        expect(event.action).to eq("egress_allowlist.account_entry_created")
      end

      it "re-renders the form with an actionable error on an unsafe host pattern" do
        expect {
          post account_egress_allowlist_entries_path,
            params: { egress_allowlist_entry: { host_pattern: "*.com" } }
        }.not_to change(EgressAllowlistEntry, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("Wildcard top-level domains")
      end

      it "does not record an audit event when the entry is invalid" do
        expect {
          post account_egress_allowlist_entries_path,
            params: { egress_allowlist_entry: { host_pattern: "*.com" } }
        }.not_to change(AccountActivityEvent, :count)
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        post account_egress_allowlist_entries_path, params: valid_params
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end

    context "when authenticated as viewer" do
      let(:viewer) { create(:user, :viewer, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in viewer
      end

      it "redirects with authorization error" do
        post account_egress_allowlist_entries_path, params: valid_params
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "PATCH /account_egress_allowlist_entries/:id" do
    let!(:entry) { create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com") }

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "toggles the entry's enabled state" do
        patch account_egress_allowlist_entry_path(entry),
          params: { egress_allowlist_entry: { enabled: false } }

        expect(response).to redirect_to(account_egress_allowlist_entries_path)
        expect(entry.reload).not_to be_enabled
        expect(entry.disabled_at).to be_present
      end

      it "records an audit event" do
        expect {
          patch account_egress_allowlist_entry_path(entry),
            params: { egress_allowlist_entry: { enabled: false } }
        }.to change(AccountActivityEvent, :count).by(1)

        expect(AccountActivityEvent.last.action).to eq("egress_allowlist.account_entry_updated")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        patch account_egress_allowlist_entry_path(entry),
          params: { egress_allowlist_entry: { enabled: false } }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end

  describe "DELETE /account_egress_allowlist_entries/:id" do
    let!(:entry) { create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com") }

    context "when authenticated as admin" do
      before do
        user.add_role(:admin, account)
        sign_in user
      end

      it "destroys the entry" do
        expect {
          delete account_egress_allowlist_entry_path(entry)
        }.to change(EgressAllowlistEntry, :count).by(-1)

        expect(response).to redirect_to(account_egress_allowlist_entries_path)
      end

      it "records an audit event" do
        expect {
          delete account_egress_allowlist_entry_path(entry)
        }.to change(AccountActivityEvent, :count).by(1)

        expect(AccountActivityEvent.last.action).to eq("egress_allowlist.account_entry_removed")
      end
    end

    context "when authenticated as member" do
      let(:member) { create(:user, :member, account: account) }

      before do
        create(:user, account: account) # absorb owner role
        sign_in member
      end

      it "redirects with authorization error" do
        delete account_egress_allowlist_entry_path(entry)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not authorized")
      end
    end
  end
end
