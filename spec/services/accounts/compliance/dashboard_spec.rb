# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Compliance::Dashboard do
  describe ".call" do
    let(:account) { create(:account) }
    let(:tenant_setting) { account.tenant_setting! }
    let(:recent_deployment_assurance) do
      {
        "deployment_model" => "byoc",
        "tenant_isolation" => "customer_cloud",
        "network_boundary" => "customer_vpc",
        "reference_architecture" => "customer_cloud_stack",
        "operations_owner" => "platform@example.com",
        "monitoring" => {
          "provider" => "Datadog",
          "escalation_owner" => "sre@example.com",
          "last_reviewed_at" => 2.days.ago.to_date.iso8601
        },
        "customer_managed_keys" => {
          "enabled" => true,
          "provider" => "AWS KMS",
          "key_reference" => "arn:aws:kms:us-east-1:123:key/abc",
          "last_rotated_at" => 10.days.ago.to_date.iso8601,
          "rotation_interval_days" => 90
        },
        "secret_rotation" => {
          "documented" => true,
          "owner" => "security@example.com",
          "last_completed_at" => 7.days.ago.to_date.iso8601,
          "interval_days" => 90
        },
        "disaster_recovery" => {
          "backup_cadence" => "daily",
          "backup_last_verified_at" => 5.days.ago.to_date.iso8601,
          "restore_last_tested_at" => 20.days.ago.to_date.iso8601,
          "upgrade_last_validated_at" => 30.days.ago.to_date.iso8601,
          "reference_stack_last_validated_at" => 15.days.ago.to_date.iso8601,
          "rpo_hours" => 4,
          "rto_hours" => 8
        },
        "release_management" => {
          "upgrade_channel" => "extended_support",
          "maintenance_window" => "Sun 02:00-04:00",
          "maintenance_timezone" => "UTC",
          "version_support_policy" => "lts",
          "support_window_days" => 60
        },
        "byoc" => {
          "cloud_provider" => "AWS",
          "automation_stack" => "Terraform + ECS",
          "reference_stack" => "aws-terraform-v1"
        }
      }
    end

    it "surfaces default gaps for missing compliance evidence" do
      result = described_class.call(account: account, tenant_setting: tenant_setting, billing_visible: false)
      controls = result[:controls].index_by { |control| control[:id] }

      expect(result[:readiness_score]).to be < 100
      expect(controls[:monitoring_coverage][:status]).to eq(:gap)
      expect(controls[:customer_managed_keys][:status]).to eq(:not_applicable)
      expect(controls[:secret_rotation][:status]).to eq(:gap)
      expect(controls[:byoc_reference_stack][:status]).to eq(:not_applicable)
    end

    it "treats enabled customer-managed keys without supporting evidence as a gap" do
      tenant_setting.deployment_assurance_configuration = {
        "customer_managed_keys" => { "enabled" => true }
      }
      tenant_setting.save!

      result = described_class.call(account: account, tenant_setting: tenant_setting, billing_visible: false)
      controls = result[:controls].index_by { |control| control[:id] }

      expect(controls[:customer_managed_keys][:status]).to eq(:gap)
    end

    it "marks controls compliant when recent evidence is present" do
      create(:user, :owner, account: account)
      Accounts::RecordActivity.call(account: account, action: "tenant_configuration.updated")

      tenant_setting.deployment_assurance_configuration = recent_deployment_assurance
      tenant_setting.save!

      result = described_class.call(account: account, tenant_setting: tenant_setting, billing_visible: true)
      controls = result[:controls].index_by { |control| control[:id] }

      expect(result[:readiness_score]).to eq(100)
      expect(controls[:deployment_topology][:status]).to eq(:compliant)
      expect(controls[:audit_export][:status]).to eq(:compliant)
      expect(controls[:monitoring_coverage][:status]).to eq(:compliant)
      expect(controls[:customer_managed_keys][:status]).to eq(:compliant)
      expect(controls[:byoc_reference_stack][:status]).to eq(:compliant)
    end
  end
end
