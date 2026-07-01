# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Accounts::OperationsDashboards" do
  include_context "with auto capacity payload"

  let(:account) { create(:account, name: "Acme") }
  let(:owner) { create(:user, :owner, account: account) }
  let(:member) { create(:user, :member, account: account) }
  let(:operations_params) do
    {
      enterprise_operations: {
        service_levels: {
          slo_window_days: "45",
          uptime_target_percent: "99.95",
          queue_health_target_percent: "99.5",
          queue_start_slo_minutes: "12",
          urgent_response_sla_hours: "1",
          standard_response_sla_hours: "4"
        },
        disaster_recovery: {
          automated_backups_enabled: "1",
          restore_drill_interval_days: "60",
          restore_owner: "ops@example.com",
          last_restore_drill_at: Date.current.iso8601
        },
        upgrades: {
          release_channel: "lts",
          maintenance_window: "Sat 03:00 UTC",
          compatibility_lookahead_days: "21",
          last_compatibility_check_at: Date.current.iso8601,
          last_upgrade_at: Date.current.iso8601
        },
        support: {
          diagnostics_contact: "support@example.com",
          safe_remediation_mode: "approval_required",
          health_report_recipients: "ops@example.com, buyer@example.com"
        },
        capacity_management: {
          reserved_concurrency: "2",
          queue_warning_threshold: "15",
          queue_critical_threshold: "30",
          monthly_budget_alert_percent: "75"
        }
      }
    }
  end
  let(:existing_operations_configuration) do
    {
      "service_levels" => {
        "urgent_response_sla_hours" => 8,
        "standard_response_sla_hours" => 16
      },
      "support" => {
        "health_report_recipients" => "ops@example.com"
      },
      "upgrades" => {
        "last_upgrade_at" => "2026-05-01"
      },
      "capacity_management" => {
        "queue_warning_threshold" => 9,
        "queue_critical_threshold" => 18
      }
    }
  end

  before do
    allow(Accounts::Operations::AutoCapacityObserver).to receive(:call).and_return(auto_capacity_payload)
    sign_in owner
  end

  describe "GET /account_operations_dashboard" do
    it "renders the operations dashboard" do
      get account_operations_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        "Enterprise Operations &amp; Reliability",
        "Support-safe diagnostics",
        "Capacity &amp; cost controls",
        "Auto Capacity Preview",
        "Observe-only auto mode",
        "Disaster recovery",
        "Upgrade orchestration"
      )
      expect(response.body).to include(
        'name="enterprise_operations[service_levels][urgent_response_sla_hours]"',
        'name="enterprise_operations[service_levels][standard_response_sla_hours]"',
        'name="enterprise_operations[upgrades][last_upgrade_at]"',
        'name="enterprise_operations[support][health_report_recipients]"',
        'name="enterprise_operations[capacity_management][queue_warning_threshold]"',
        'name="enterprise_operations[capacity_management][queue_critical_threshold]"'
      )
    end

    it "renders degraded auto-capacity warnings when docker metrics are unavailable" do
      allow(Accounts::Operations::AutoCapacityObserver).to receive(:call).and_return(degraded_auto_capacity_payload)

      get account_operations_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        "Degraded Docker metrics",
        "Auto preview cannot make a trustworthy recommendation until Docker metrics recover.",
        "Action: verify that the Docker daemon is reachable"
      )
    end

    it "renders persisted operations settings in the editable form" do
      account.tenant_setting!.update!(
        enterprise_operations_configuration: account.tenant_setting!.enterprise_operations_configuration.deep_merge(existing_operations_configuration)
      )

      get account_operations_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        'value="8"',
        'value="16"',
        'value="2026-05-01"',
        'value="ops@example.com"',
        'value="9"',
        'value="18"'
      )
    end

    it "hides the export link from members" do
      sign_out owner
      sign_in member

      get account_operations_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Export operations report")
      expect(response.body).not_to include("Save operations settings")
    end
  end

  describe "PATCH /account_operations_dashboard" do
    it "updates enterprise operations settings and records activity" do
      expect do
        patch account_operations_dashboard_path, params: operations_params
      end.to change(AccountActivityEvent, :count).by(1)

      expect(response).to redirect_to(account_operations_dashboard_path)

      operations = account.tenant_setting!.reload.enterprise_operations_configuration
      expect(operations.dig("service_levels", "slo_window_days")).to eq(45)
      expect(operations.dig("service_levels", "uptime_target_percent")).to eq(99.95)
      expect(operations.dig("upgrades", "release_channel")).to eq("lts")
      expect(account.account_activity_events.recent.first.action).to eq("operations.dashboard_updated")
    end

    it "does not record activity for a no-op update" do
      account.tenant_setting!.update!(enterprise_operations_configuration: operations_params.fetch(:enterprise_operations))

      expect do
        patch account_operations_dashboard_path, params: operations_params
      end.not_to change(AccountActivityEvent, :count)

      expect(response).to redirect_to(account_operations_dashboard_path)
    end

    it "allows disabling automated backups" do
      account.tenant_setting!.update!(
        enterprise_operations_configuration: account.tenant_setting!.enterprise_operations_configuration.deep_merge(
          "disaster_recovery" => { "automated_backups_enabled" => true }
        )
      )

      patch account_operations_dashboard_path, params: operations_params.deep_merge(
        enterprise_operations: {
          disaster_recovery: {
            automated_backups_enabled: "0"
          }
        }
      )

      expect(response).to redirect_to(account_operations_dashboard_path)
      expect(account.tenant_setting!.reload.enterprise_operations_configuration.dig("disaster_recovery", "automated_backups_enabled")).to be(false)
    end

    it "preserves omitted enterprise operations values on partial updates" do
      tenant_setting = account.tenant_setting!
      tenant_setting.update!(
        enterprise_operations_configuration: tenant_setting.enterprise_operations_configuration.deep_merge(existing_operations_configuration)
      )

      patch account_operations_dashboard_path, params: {
        enterprise_operations: {
          service_levels: {
            slo_window_days: "45"
          }
        }
      }

      expect(response).to redirect_to(account_operations_dashboard_path)

      operations = tenant_setting.reload.enterprise_operations_configuration
      expect(operations.dig("service_levels", "slo_window_days")).to eq(45)
      expect(operations.dig("service_levels", "urgent_response_sla_hours")).to eq(8)
      expect(operations.dig("service_levels", "standard_response_sla_hours")).to eq(16)
      expect(operations.dig("support", "health_report_recipients")).to eq("ops@example.com")
      expect(operations.dig("upgrades", "last_upgrade_at")).to eq("2026-05-01")
      expect(operations.dig("capacity_management", "queue_warning_threshold")).to eq(9)
      expect(operations.dig("capacity_management", "queue_critical_threshold")).to eq(18)
    end

    it "rejects invalid enterprise operations values" do
      patch account_operations_dashboard_path, params: operations_params.deep_merge(
        enterprise_operations: {
          service_levels: { uptime_target_percent: "1000" },
          support: { safe_remediation_mode: "freeform" }
        }
      )

      expect(response).to have_http_status(:unprocessable_content)

      operations = account.tenant_setting!.reload.enterprise_operations_configuration
      expect(operations.dig("service_levels", "uptime_target_percent")).to eq(99.9)
      expect(operations.dig("support", "safe_remediation_mode")).to eq("approval_required")
    end
  end

  describe "GET /account_operations_dashboard/export" do
    it "exports the health report as JSON" do
      AccountActivityEvent.create!(
        account: account,
        actor: owner,
        action: "operations.dashboard_updated",
        metadata: { "changed_fields" => [ "enterprise_operations" ] }
      )

      get export_account_operations_dashboard_path(format: :json)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")

      body = JSON.parse(response.body)
      expect(body.fetch("account").fetch("name")).to eq("Acme")
      expect(body).to include("operations_dashboard", "queue_depths", "runner_health", "open_incidents")
      expect(body.fetch("recent_activity").first.fetch("actor")).to eq(owner.email)
    end

    it "forbids members from exporting the health report" do
      sign_out owner
      sign_in member

      get export_account_operations_dashboard_path(format: :json)

      expect(response).to redirect_to(root_path)
    end
  end

  def degraded_auto_capacity_payload
    auto_capacity_payload.merge(
      status: :degraded,
      effective_recommended_concurrency: nil,
      available_agent_memory_bytes: nil,
      docker_cpu_count: nil,
      docker_memory_bytes: nil,
      running_agent_count: nil,
      control_plane_margin_bytes: nil,
      warnings: [ "Auto preview is degraded because Docker metrics could not be collected." ],
      auto_mode_summary: "Auto preview cannot make a trustworthy recommendation until Docker metrics recover.",
      comparison_summary: "Keep using manual mode until the Docker inspection path is healthy again."
    )
  end
end
