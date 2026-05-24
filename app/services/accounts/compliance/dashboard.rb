# frozen_string_literal: true

module Accounts
  module Compliance
    class Dashboard
      REFERENCE_ARCHITECTURES = [
        {
          key: "self_hosted",
          name: "Self-hosted",
          summary: "Single-tenant deployment with isolated Rails, PostgreSQL, Redis, and object storage.",
          doc_path: "docs/compliance/reference-architectures.md#self-hosted-reference-architecture"
        },
        {
          key: "private_vpc",
          name: "Private VPC",
          summary: "Private-network deployment with controlled ingress, egress, and managed persistence services.",
          doc_path: "docs/compliance/reference-architectures.md#private-vpc-reference-architecture"
        },
        {
          key: "air_gapped",
          name: "Air-gapped",
          summary: "Offline package promotion model for environments that prohibit direct internet connectivity.",
          doc_path: "docs/compliance/reference-architectures.md#air-gapped-reference-architecture"
        }
      ].freeze

      RUNBOOKS = [
        {
          key: "backup_restore",
          name: "Backup and Restore",
          summary: "Backup cadence, restore rehearsal, and evidence capture expectations.",
          doc_path: "docs/compliance/operational-assurance-runbooks.md#backup-and-restore"
        },
        {
          key: "upgrade_validation",
          name: "Upgrade Validation",
          summary: "Pre-upgrade checks, rollback planning, and post-upgrade verification.",
          doc_path: "docs/compliance/operational-assurance-runbooks.md#upgrade-validation"
        },
        {
          key: "secret_rotation",
          name: "Secret Rotation",
          summary: "Customer-managed key rotation and provider credential renewal workflow.",
          doc_path: "docs/compliance/operational-assurance-runbooks.md#secret-rotation"
        }
      ].freeze

      CONTROL_MAPPINGS = {
        deployment_topology: {
          title: "Deployment topology documented",
          requirement: "Reference architecture, network boundary, and operator ownership are recorded.",
          mappings: [ "SOC 2 CC1.2", "SOC 2 CC6.6", "ISO 27001 A.5.8" ],
          guidance: "Capture the deployment model and operations owner used for this tenant."
        },
        configuration_snapshot: {
          title: "Configuration snapshot exportable",
          requirement: "Security reviewers can inspect account and tenant configuration without bespoke screenshots.",
          mappings: [ "SOC 2 CC2.1", "ISO 27001 A.5.37" ],
          guidance: "Use the evidence export to attach current account and tenant configuration to a review."
        },
        audit_export: {
          title: "Audit activity exportable",
          requirement: "Administrative actions are recorded and can be exported for review.",
          mappings: [ "SOC 2 CC7.2", "ISO 27001 A.8.15" ],
          guidance: "Generate an evidence pack after lifecycle, membership, or tenant configuration changes."
        },
        customer_managed_keys: {
          title: "Customer-managed key posture",
          requirement: "The tenant documents whether a customer-managed key is enabled and where it is rotated.",
          mappings: [ "SOC 2 CC6.1", "ISO 27001 A.8.24" ],
          guidance: "Record the KMS provider, key reference, and last rotation date for buyer review."
        },
        secret_rotation: {
          title: "Secret rotation workflow",
          requirement: "Credential rotation has an owner, cadence, and recent execution evidence.",
          mappings: [ "SOC 2 CC6.1", "ISO 27001 A.5.17" ],
          guidance: "Track the operator owner and the last completed secret rotation date."
        },
        backup_verification: {
          title: "Backup verification",
          requirement: "Backups have a declared cadence and recent verification evidence.",
          mappings: [ "SOC 2 A1.2", "ISO 27001 A.8.13" ],
          guidance: "Record the backup cadence and when the most recent backup verification completed."
        },
        restore_validation: {
          title: "Restore validation",
          requirement: "Disaster recovery restores are tested on a recurring basis.",
          mappings: [ "SOC 2 A1.3", "ISO 27001 A.5.30" ],
          guidance: "Run and record a restore exercise at least once per quarter."
        },
        upgrade_validation: {
          title: "Upgrade validation",
          requirement: "Upgrades are rehearsed with rollback planning before production rollout.",
          mappings: [ "SOC 2 CC8.1", "ISO 27001 A.8.32" ],
          guidance: "Record the most recent validated upgrade rehearsal and expected rollback window."
        },
        air_gap_validation: {
          title: "Air-gap package validation",
          requirement: "Offline deployment packages are validated when the tenant uses an air-gapped model.",
          mappings: [ "SOC 2 CC6.7", "ISO 27001 A.5.14" ],
          guidance: "Re-validate offline artifacts whenever the deployment package or dependencies change."
        }
      }.freeze

      def self.call(...)
        new(...).call
      end

      def initialize(account:, tenant_setting:, billing_visible: false)
        @account = account
        @tenant_setting = tenant_setting
        @billing_visible = billing_visible
      end

      def call
        controls = [
          deployment_topology_control,
          configuration_snapshot_control,
          audit_export_control,
          customer_managed_keys_control,
          secret_rotation_control,
          backup_verification_control,
          restore_validation_control,
          upgrade_validation_control,
          air_gap_validation_control
        ]

        applicable_controls = controls.reject { |control| control[:status] == :not_applicable }
        counts = {
          compliant: applicable_controls.count { |control| control[:status] == :compliant },
          warning: applicable_controls.count { |control| control[:status] == :warning },
          gap: applicable_controls.count { |control| control[:status] == :gap },
          not_applicable: controls.count { |control| control[:status] == :not_applicable }
        }

        readiness_score =
          if applicable_controls.empty?
            100
          else
            (((counts[:compliant] + (counts[:warning] * 0.5)) / applicable_controls.size.to_f) * 100).round
          end

        {
          deployment_assurance: deployment_assurance,
          reference_architectures: REFERENCE_ARCHITECTURES,
          runbooks: RUNBOOKS,
          controls: controls,
          counts: counts,
          readiness_score: readiness_score,
          billing_visible: billing_visible
        }
      end

      private

      attr_reader :account, :tenant_setting, :billing_visible

      def deployment_assurance
        tenant_setting.deployment_assurance_configuration
      end

      def control(id, status:, evidence:)
        CONTROL_MAPPINGS.fetch(id).merge(id: id, status: status, evidence: evidence)
      end

      def deployment_topology_control
        owner = deployment_assurance["operations_owner"].to_s
        status = owner.present? ? :compliant : :warning

        control(
          :deployment_topology,
          status: status,
          evidence: [
            "Deployment model: #{deployment_assurance['deployment_model'].humanize}",
            "Network boundary: #{deployment_assurance['network_boundary'].humanize}",
            "Reference architecture: #{deployment_assurance['reference_architecture'].humanize}",
            owner.presence ? "Operations owner: #{owner}" : "Operations owner missing"
          ]
        )
      end

      def configuration_snapshot_control
        control(
          :configuration_snapshot,
          status: :compliant,
          evidence: [
            "Tenant settings snapshot available",
            "Account defaults included in evidence export"
          ]
        )
      end

      def audit_export_control
        event_count = account.account_activity_events.count
        status = event_count.positive? ? :compliant : :warning

        control(
          :audit_export,
          status: status,
          evidence: [
            "Recent account activity entries: #{event_count}",
            "Administrative audit export available from evidence pack"
          ]
        )
      end

      def customer_managed_keys_control
        keys = deployment_assurance["customer_managed_keys"]
        enabled = keys["enabled"] == true
        status =
          if enabled && keys["provider"].present? && keys["key_reference"].present?
            if fresh_within?(keys["last_rotated_at"], days: keys["rotation_interval_days"].presence || 90)
              :compliant
            else
              :warning
            end
          else
            :gap
          end

        control(
          :customer_managed_keys,
          status: status,
          evidence: [
            "Enabled: #{enabled ? 'Yes' : 'No'}",
            "Provider: #{keys['provider'].presence || 'Not recorded'}",
            "Key reference: #{keys['key_reference'].presence || 'Not recorded'}",
            "Last rotated: #{display_date(keys['last_rotated_at'])}",
            "Rotation interval: #{keys['rotation_interval_days']} days"
          ]
        )
      end

      def secret_rotation_control
        rotation = deployment_assurance["secret_rotation"]
        documented = rotation["documented"] == true
        interval_days = rotation["interval_days"].presence || 90

        status =
          if documented && rotation["owner"].present? && fresh_within?(rotation["last_completed_at"], days: interval_days)
            :compliant
          elsif documented && rotation["owner"].present?
            :warning
          else
            :gap
          end

        control(
          :secret_rotation,
          status: status,
          evidence: [
            "Workflow documented: #{documented ? 'Yes' : 'No'}",
            "Owner: #{rotation['owner'].presence || 'Not recorded'}",
            "Last completed: #{display_date(rotation['last_completed_at'])}",
            "Rotation interval: #{interval_days} days"
          ]
        )
      end

      def backup_verification_control
        recovery = deployment_assurance["disaster_recovery"]
        status =
          if fresh_within?(recovery["backup_last_verified_at"], days: 30)
            :compliant
          elsif parse_date(recovery["backup_last_verified_at"])
            :warning
          else
            :gap
          end

        control(
          :backup_verification,
          status: status,
          evidence: [
            "Backup cadence: #{recovery['backup_cadence'].humanize}",
            "Last verified: #{display_date(recovery['backup_last_verified_at'])}",
            "Target RPO: #{recovery['rpo_hours']} hours"
          ]
        )
      end

      def restore_validation_control
        recovery = deployment_assurance["disaster_recovery"]
        status =
          if fresh_within?(recovery["restore_last_tested_at"], days: 90)
            :compliant
          elsif parse_date(recovery["restore_last_tested_at"])
            :warning
          else
            :gap
          end

        control(
          :restore_validation,
          status: status,
          evidence: [
            "Last restore test: #{display_date(recovery['restore_last_tested_at'])}",
            "Target RTO: #{recovery['rto_hours']} hours"
          ]
        )
      end

      def upgrade_validation_control
        recovery = deployment_assurance["disaster_recovery"]
        status =
          if fresh_within?(recovery["upgrade_last_validated_at"], days: 90)
            :compliant
          elsif parse_date(recovery["upgrade_last_validated_at"])
            :warning
          else
            :gap
          end

        control(
          :upgrade_validation,
          status: status,
          evidence: [
            "Last validated upgrade: #{display_date(recovery['upgrade_last_validated_at'])}",
            "Rollback planning documented in runbook"
          ]
        )
      end

      def air_gap_validation_control
        unless deployment_assurance["deployment_model"] == "air_gapped"
          return control(
            :air_gap_validation,
            status: :not_applicable,
            evidence: [ "Tenant is not using an air-gapped deployment model" ]
          )
        end

        recovery = deployment_assurance["disaster_recovery"]
        status =
          if fresh_within?(recovery["air_gap_package_validated_at"], days: 90)
            :compliant
          elsif parse_date(recovery["air_gap_package_validated_at"])
            :warning
          else
            :gap
          end

        control(
          :air_gap_validation,
          status: status,
          evidence: [
            "Offline package validated: #{display_date(recovery['air_gap_package_validated_at'])}"
          ]
        )
      end

      def fresh_within?(value, days:)
        date = parse_date(value)
        date.present? && date >= days.days.ago.to_date
      end

      def parse_date(value)
        return value.to_date if value.respond_to?(:to_date)
        return nil if value.blank?

        Date.parse(value.to_s)
      rescue Date::Error
        nil
      end

      def display_date(value)
        parse_date(value)&.iso8601 || "Not recorded"
      end
    end
  end
end
