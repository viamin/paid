# frozen_string_literal: true

require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_change, :change

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
      expect(response.body).to include(
        "Account Administration",
        "Team",
        "Tenant Limits and Usage",
        "ROI, Evals & Benchmarking",
        "Compliance & Deployment Assurance",
        "Adoption &amp; Operational Readiness",
        "Admin playbooks",
        "Role-based training &amp; onboarding",
        "Reference operating models",
        "Billing",
        "Activity Trail"
      )
    end

    it "allows a viewer to read the page" do
      viewer = create(:user, :viewer, account: account)
      sign_out owner
      sign_in viewer

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Account Administration")
    end

    it "hides compliance evidence export from non-admin readers" do
      viewer = create(:user, :viewer, account: account)
      sign_out owner
      sign_in viewer

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Export evidence")
    end
  end

  describe "GET /account_audit_logs" do
    it "renders the audit log page with recent account activity" do
      account.account_activity_events.create!(
        action: "membership.invited",
        actor: owner,
        metadata: { email: "new-user@example.com", role: "admin" }
      )

      get account_audit_logs_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Audit Log")
      expect(response.body).to include("Export JSON")
      expect(response.body).to include("Invited new-user@example.com as admin")
    end

    it "exports the audit log as JSON" do
      event = account.account_activity_events.create!(
        action: "project.created",
        actor: owner,
        metadata: { name: "Roadrunner", github_url: "https://github.com/acme/roadrunner" }
      )

      get export_account_audit_logs_path(format: :json)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(JSON.parse(response.body)).to include(
        a_hash_including(
          "id" => event.id,
          "action" => "project.created",
          "actor" => owner.email
        )
      )
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

    it "rolls back the account update when activity recording fails" do
      allow(Accounts::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(AccountActivityEvent.new))

      expect do
        patch account_path, params: {
          account: {
            name: "Acme Labs"
          }
        }
      end.not_to change(AccountActivityEvent, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload.name).to eq("Acme")
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

    it "rejects inviting an existing user from another account" do
      existing_user = create(:user, :member, email: "shared@example.com")

      expect do
        post account_memberships_path, params: {
          invitation: {
            email: "shared@example.com",
            role: "member"
          }
        }
      end.to not_change(AccountMembership, :count)
        .and not_change(AccountActivityEvent, :count)

      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to include("Cross-account invites are not supported yet")
      expect(account.account_memberships.find_by(user: existing_user)).to be_nil
      expect(User.find_by!(email: "shared@example.com")).to eq(existing_user)
      expect(existing_user.reload.account).not_to eq(account)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "does not send reset instructions when the invite transaction rolls back" do
      allow(Accounts::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(AccountActivityEvent.new))

      expect do
        post account_memberships_path, params: {
          invitation: {
            email: "rolled-back@example.com",
            role: "member"
          }
        }
      end.not_to change(ActionMailer::Base.deliveries, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(User.find_by(email: "rolled-back@example.com")).to be_nil
    end

    it "refuses to invite an owner via the membership flow" do
      expect do
        post account_memberships_path, params: {
          invitation: {
            email: "new-owner@example.com",
            role: "owner"
          }
        }
      end.not_to change(AccountMembership, :count)

      expect(response).to redirect_to(account_path)
      expect(flash[:alert]).to include("ownership transfer")
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

    it "rolls back the role change when activity recording fails" do
      membership = create(:account_membership, :member, account: account, user: create(:user, account: account))
      allow(Accounts::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(AccountActivityEvent.new))

      patch account_membership_path(membership), params: {
        account_membership: { role: "admin" }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(membership.reload.role).to eq("member")
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
      end.to change(User, :count).by(-1)
        .and change(AccountMembership, :count).by(-1)
        .and change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(account.account_activity_events.recent.first.action).to eq("membership.removed")
    end

    it "switches the removed user to another account when they still have one" do
      membership = create(:account_membership, :viewer, account: account, user: create(:user, account: account))
      secondary_account = create(:account)
      create(:account_membership, :member, user: membership.user, account: secondary_account)

      expect do
        delete account_membership_path(membership)
      end.to change(AccountMembership, :count).by(-1)
        .and change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(membership.user.reload.account).to eq(secondary_account)
    end

    it "rolls back the removal when activity recording fails" do
      membership = create(:account_membership, :viewer, account: account, user: create(:user, account: account))
      allow(Accounts::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(AccountActivityEvent.new))

      delete account_membership_path(membership)

      expect(response).to have_http_status(:unprocessable_content)
      expect(membership.reload).to be_present
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

    it "switches the new owner's active account when they belong to another account" do
      secondary_account = create(:account)
      transferee = create(:user, :admin, account: secondary_account)
      membership = create(:account_membership, :admin, account: account, user: transferee)

      post account_ownership_transfer_path, params: { membership_id: membership.id }

      expect(response).to redirect_to(account_path)
      expect(transferee.reload.account).to eq(account)

      sign_out owner
      sign_in transferee

      get account_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Account Administration")
    end

    it "rolls back the transfer when activity recording fails" do
      membership = create(:account_membership, :admin, account: account, user: create(:user, account: account))
      allow(Accounts::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(AccountActivityEvent.new))

      post account_ownership_transfer_path, params: { membership_id: membership.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(membership.reload.role).to eq("admin")
      expect(owner.account_membership_for(account).reload.role).to eq("owner")
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

    it "rolls back the transition when activity recording fails" do
      allow(Accounts::RecordActivity).to receive(:call).and_raise(ActiveRecord::RecordInvalid.new(AccountActivityEvent.new))

      patch account_lifecycle_path, params: { transition: "suspend" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload).to be_active
    end

    it "rejects admins" do
      admin = create(:user, :admin, account: account)
      sign_out owner
      sign_in admin

      patch account_lifecycle_path, params: { transition: "suspend" }

      expect(response).to redirect_to(root_path)
      expect(account.reload).to be_active
    end

    it "reactivates a suspended account and records activity" do
      account.suspend!

      expect do
        patch account_lifecycle_path, params: { transition: "reactivate" }
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(account.reload).to be_active
      expect(account.account_activity_events.recent.first.action).to eq("lifecycle.reactivated")
    end

    it "deactivates a suspended account and records activity" do
      account.suspend!

      expect do
        patch account_lifecycle_path, params: { transition: "deactivate" }
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_path)
      expect(account.reload).to be_deactivated
      expect(account.account_activity_events.recent.first.action).to eq("lifecycle.deactivated")
    end

    it "does not render a self-service reactivation button for deactivated accounts" do
      account.suspend!
      account.deactivate!

      get account_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
