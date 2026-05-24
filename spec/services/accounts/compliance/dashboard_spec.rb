# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Compliance::Dashboard do
  describe ".call" do
    let(:account) { create(:account) }
    let(:tenant_setting) { account.tenant_setting! }
    let(:recent_deployment_assurance) do
      {
        "deployment_model" => "air_gapped",
        "network_boundary" => "offline",
        "reference_architecture" => "offline_promotion",
        "operations_owner" => "platform@example.com",
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
          "air_gap_package_validated_at" => 15.days.ago.to_date.iso8601,
          "rpo_hours" => 4,
          "rto_hours" => 8
        }
      }
    end

    it "surfaces default gaps for missing compliance evidence" do
      result = described_class.call(account: account, tenant_setting: tenant_setting, billing_visible: false)
      controls = result[:controls].index_by { |control| control[:id] }

      expect(result[:readiness_score]).to be < 100
      expect(controls[:customer_managed_keys][:status]).to eq(:gap)
      expect(controls[:secret_rotation][:status]).to eq(:gap)
      expect(controls[:air_gap_validation][:status]).to eq(:not_applicable)
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
      expect(controls[:customer_managed_keys][:status]).to eq(:compliant)
      expect(controls[:air_gap_validation][:status]).to eq(:compliant)
    end
  end
end
