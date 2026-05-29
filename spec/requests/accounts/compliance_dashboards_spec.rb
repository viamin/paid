# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Accounts::ComplianceDashboards" do
  let(:account) { create(:account, name: "Acme") }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:deployment_assurance_params) do
    {
      deployment_assurance: {
        deployment_model: "byoc",
        tenant_isolation: "customer_cloud",
        network_boundary: "customer_vpc",
        reference_architecture: "customer_cloud_stack",
        operations_owner: "platform@example.com",
        monitoring: {
          provider: "Datadog",
          escalation_owner: "sre@example.com",
          last_reviewed_at: Date.current.iso8601
        },
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
          reference_stack_last_validated_at: Date.current.iso8601,
          rpo_hours: "4",
          rto_hours: "8"
        },
        release_management: {
          upgrade_channel: "extended_support",
          maintenance_window: "Sun 02:00-04:00",
          maintenance_timezone: "UTC",
          version_support_policy: "lts",
          support_window_days: "60"
        },
        byoc: {
          cloud_provider: "AWS",
          automation_stack: "Terraform + ECS",
          reference_stack: "aws-terraform-v1"
        }
      }
    }
  end
  let(:unsupported_option_params) do
    deployment_assurance_params.deep_merge(
      deployment_assurance: {
        deployment_model: "public_cloud",
        tenant_isolation: "shared_everything",
        network_boundary: "open_internet",
        reference_architecture: "shared_tenant",
        release_management: {
          upgrade_channel: "fast_ring",
          version_support_policy: "forever"
        },
        disaster_recovery: {
          backup_cadence: "monthly"
        }
      }
    )
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

    it "renders currently stored legacy deployment assurance options" do
      account.tenant_setting!.update!(
        features: {
          "deployment_assurance" => {
            "deployment_model" => "air_gapped",
            "tenant_isolation" => "single_tenant",
            "network_boundary" => "offline",
            "reference_architecture" => "offline_promotion"
          }
        }
      )

      get account_compliance_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('value="air_gapped"')
      expect(response.body).to include("Air gapped (legacy)")
      expect(response.body).to include('value="offline"')
      expect(response.body).to include("Offline (legacy)")
      expect(response.body).to include('value="offline_promotion"')
      expect(response.body).to include("Offline promotion (legacy)")
    end
  end

  describe "PATCH /account_compliance_dashboard" do
    it "updates deployment assurance settings and records activity" do
      expect do
        patch account_compliance_dashboard_path, params: deployment_assurance_params
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_compliance_dashboard_path)

      assurance = account.tenant_setting!.reload.deployment_assurance_configuration
      expect(assurance["deployment_model"]).to eq("byoc")
      expect(assurance["tenant_isolation"]).to eq("customer_cloud")
      expect(assurance.dig("monitoring", "provider")).to eq("Datadog")
      expect(assurance.dig("customer_managed_keys", "enabled")).to be(true)
      expect(assurance.dig("secret_rotation", "interval_days")).to eq(60)
      expect(assurance.dig("release_management", "upgrade_channel")).to eq("extended_support")
      expect(assurance.dig("byoc", "reference_stack")).to eq("aws-terraform-v1")
      expect(account.account_activity_events.recent.first.action).to eq("compliance.assurance_updated")
    end

    it "rejects invalid numeric deployment assurance settings" do
      expect do
        patch account_compliance_dashboard_path, params: deployment_assurance_params.deep_merge(
          deployment_assurance: {
            release_management: { support_window_days: "oops" }
          }
        )
      end.not_to change(AccountActivityEvent, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.tenant_setting!.reload.deployment_assurance_configuration.dig("release_management", "support_window_days")).to eq(30)
    end

    it "rejects unsupported deployment assurance option values" do
      patch account_compliance_dashboard_path, params: unsupported_option_params

      expect(response).to have_http_status(:unprocessable_content)

      assurance = account.tenant_setting!.reload.deployment_assurance_configuration
      expect(assurance["deployment_model"]).to eq("managed_cloud")
      expect(assurance["tenant_isolation"]).to eq("multi_tenant_rls")
      expect(assurance["network_boundary"]).to eq("paid_managed")
      expect(assurance["reference_architecture"]).to eq("managed_control_plane")
      expect(assurance.dig("disaster_recovery", "backup_cadence")).to eq("daily")
      expect(assurance.dig("release_management", "upgrade_channel")).to eq("stable")
      expect(assurance.dig("release_management", "version_support_policy")).to eq("n_minus_one")
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
