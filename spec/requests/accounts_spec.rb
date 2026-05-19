# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Accounts" do
  let(:account) { create(:account, name: "Acme") }
  let(:owner) { create(:user, :owner, account: account) }

  before do
    ActionMailer::Base.deliveries.clear
    sign_in owner
  end

  describe "GET /account" do
    it "renders the account administration page" do
      create(:user, :member, account: account)
      create(:billing_plan, :per_run, account: account, name: "Growth")
      period = create(:billing_period, :with_usage, account: account)
      create(:billing_invoice, :issued, account: account, billing_period: period, total_cents: 7800)

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Account Administration")
      expect(response.body).to include("Team")
      expect(response.body).to include("Tenant Limits and Usage")
      expect(response.body).to include("Billing")
      expect(response.body).to include("Activity Trail")
    end

    it "allows a viewer to read the page" do
      viewer = create(:user, :viewer, account: account)
      sign_out owner
      sign_in viewer

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Account Administration")
    end
  end

  describe "PATCH /account" do
    it "updates editable account settings and records activity" do
      expect do
        patch account_path, params: {
          account: {
            name: "Acme Labs",
            default_max_tokens_per_run: 200_000
          }
        }
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(account.reload.name).to eq("Acme Labs")
      expect(account.default_max_tokens_per_run).to eq(200_000)

      event = account.account_activity_events.recent.first
      expect(event.action).to eq("account.updated")
      expect(event.metadata["changed_fields"]).to include("name", "default_max_tokens_per_run")
    end

    it "rejects viewers" do
      viewer = create(:user, :viewer, account: account)
      sign_out owner
      sign_in viewer

      patch account_path, params: { account: { name: "Blocked" } }

      expect(response).to redirect_to(root_path)
      expect(account.reload.name).to eq("Acme")
    end
  end

  describe "POST /account_memberships" do
    it "invites a user, creates a membership, sends reset instructions, and records activity" do
      expect do
        post account_memberships_path, params: {
          invitation: {
            email: "new-user@example.com",
            name: "New User",
            role: "admin"
          }
        }
      end.to change(User, :count).by(1)
        .and change(AccountMembership, :count).by(1)
        .and change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      membership = account.account_memberships.includes(:user).find_by!(user: { email: "new-user@example.com" })
      expect(membership.role).to eq("admin")
      expect(ActionMailer::Base.deliveries.last.to).to eq([ "new-user@example.com" ])
      expect(account.account_activity_events.recent.first.action).to eq("membership.invited")
    end

    it "rejects inviting an email that belongs to another account" do
      create(:user, email: "shared@example.com")

      expect do
        post account_memberships_path, params: {
          invitation: {
            email: "shared@example.com",
            role: "member"
          }
        }
      end.not_to change(AccountMembership, :count)

      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to include("another account")
    end
  end

  describe "PATCH /account_memberships/:id" do
    it "changes a non-owner role and records activity" do
      membership = create(:account_membership, :member, account: account, user: create(:user, account: account))

      expect do
        patch account_membership_path(membership), params: {
          account_membership: { role: "admin" }
        }
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(membership.reload.role).to eq("admin")
      expect(account.account_activity_events.recent.first.action).to eq("membership.role_changed")
    end

    it "refuses to assign owner via role change" do
      membership = create(:account_membership, :member, account: account, user: create(:user, account: account))

      patch account_membership_path(membership), params: {
        account_membership: { role: "owner" }
      }

      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to include("ownership transfer")
      expect(membership.reload.role).to eq("member")
    end
  end

  describe "DELETE /account_memberships/:id" do
    it "removes a non-owner membership and records activity" do
      membership = create(:account_membership, :viewer, account: account, user: create(:user, account: account))

      expect do
        delete account_membership_path(membership)
      end.to change(AccountMembership, :count).by(-1)
        .and change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(account.account_activity_events.recent.first.action).to eq("membership.removed")
    end
  end

  describe "POST /account_ownership_transfer" do
    it "transfers ownership and records activity" do
      membership = create(:account_membership, :admin, account: account, user: create(:user, account: account))

      expect do
        post account_ownership_transfer_path, params: { membership_id: membership.id }
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(membership.reload.role).to eq("owner")
      expect(owner.account_membership_for(account).reload.role).to eq("admin")
      expect(account.account_activity_events.recent.first.action).to eq("ownership.transferred")
    end
  end

  describe "PATCH /account_lifecycle" do
    it "suspends the account and records activity" do
      expect do
        patch account_lifecycle_path, params: { transition: "suspend" }
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(account.reload).to be_suspended
      expect(account.account_activity_events.recent.first.action).to eq("lifecycle.suspended")
    end

    it "rejects admins" do
      admin = create(:user, :admin, account: account)
      sign_out owner
      sign_in admin

      patch account_lifecycle_path, params: { transition: "suspend" }

      expect(response).to redirect_to(root_path)
      expect(account.reload).to be_active
    end
  end
end
