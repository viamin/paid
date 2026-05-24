# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Accounts::ComplianceDashboards" do
  let(:account) { create(:account, name: "Acme") }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:deployment_assurance_params) do
    {
      deployment_assurance: {
        deployment_model: "private_vpc",
        network_boundary: "private_vpc",
        reference_architecture: "private_services",
        operations_owner: "platform@example.com",
        customer_managed_keys: {
          enabled: "1",
          provider: "AWS KMS",
          key_reference: "arn:aws:kms:us-east-1:123:key/abc",
          last_rotated_at: Date.current.iso8601,
          rotation_interval_days: "90"
        },
        secret_rotation: {
          documented: "1",
          owner: "security@example.com",
          last_completed_at: Date.current.iso8601,
          interval_days: "60"
        },
        disaster_recovery: {
          backup_cadence: "daily",
          backup_last_verified_at: Date.current.iso8601,
          restore_last_tested_at: Date.current.iso8601,
          upgrade_last_validated_at: Date.current.iso8601,
          air_gap_package_validated_at: "",
          rpo_hours: "4",
          rto_hours: "8"
        }
      }
    }
  end

  before do
    sign_in owner
  end

  describe "GET /account_compliance_dashboard" do
    it "renders the compliance dashboard" do
      get account_compliance_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Deployment Assurance")
      expect(response.body).to include("Control gaps")
      expect(response.body).to include("Reference architectures")
    end

    it "hides the evidence export link from members" do
      sign_out owner
      sign_in member

      get account_compliance_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Export evidence pack")
      expect(response.body).not_to include("Save compliance settings")
    end
  end

  describe "PATCH /account_compliance_dashboard" do
    it "updates deployment assurance settings and records activity" do
      expect do
        patch account_compliance_dashboard_path, params: deployment_assurance_params
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_compliance_dashboard_path)

      assurance = account.tenant_setting!.reload.deployment_assurance_configuration
      expect(assurance["deployment_model"]).to eq("private_vpc")
      expect(assurance.dig("customer_managed_keys", "enabled")).to be(true)
      expect(assurance.dig("secret_rotation", "interval_days")).to eq(60)
      expect(account.account_activity_events.recent.first.action).to eq("compliance.assurance_updated")
    end
  end

  describe "GET /account_compliance_dashboard/export" do
    it "exports the evidence pack as JSON" do
      get export_account_compliance_dashboard_path(format: :json)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")

      body = JSON.parse(response.body)
      expect(body.fetch("account").fetch("name")).to eq("Acme")
      expect(body).to include("control_summary", "controls", "configuration_snapshot", "audit_export")
    end

    it "forbids members from exporting the evidence pack" do
      sign_out owner
      sign_in member

      get export_account_compliance_dashboard_path(format: :json)

      expect(response).to redirect_to(root_path)
    end
  end
end
