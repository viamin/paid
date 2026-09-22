# frozen_string_literal: true

class CreateAppleVerificationImages < ActiveRecord::Migration[8.1]
  def change
    create_table :apple_verification_images, comment: "Operator-published immutable macOS guest images for Apple verification." do |t|
      t.references :account, null: false, foreign_key: true, comment: "Account whose operator-approved worker catalog contains this image."
      t.string :name, null: false, comment: "Operator-visible logical worker profile name."
      t.string :digest, null: false, comment: "Immutable sha256 content digest of the macOS VM image."
      t.jsonb :toolchain, null: false, default: {}, comment: "macOS, Xcode, SDK, Simulator runtime, and executor versions."
      t.jsonb :resources, null: false, default: {}, comment: "Approved guest CPU, memory, and disk envelope."
      t.jsonb :network_capability, null: false, default: {}, comment: "Guest network mechanism and policy-enforcement declaration."
      t.jsonb :gui_account, null: false, default: {}, comment: "Dedicated verification-account security posture."
      t.jsonb :smoke_test, null: false, default: {}, comment: "Isolation and toolchain smoke-test result used for promotion."
      t.jsonb :provenance, null: false, default: {}, comment: "Non-secret operator build provenance and runbook references."
      t.string :status, null: false, default: "candidate", comment: "candidate, active, deprecated, retired, or revoked; only active images accept new work."
      t.datetime :promoted_at, comment: "Time a smoke-tested candidate was promoted."
      t.datetime :deprecated_at, comment: "Time the image was deprecated."
      t.datetime :retirement_at, comment: "Scheduled or completed retirement time."
      t.text :deprecation_reason, comment: "Reason and migration guidance for deprecation or retirement."
      t.datetime :revoked_at, comment: "Time an operator immediately revoked the image."
      t.text :revocation_reason, comment: "Security or operational reason for immediate revocation."
      t.timestamps
    end

    add_index :apple_verification_images, [ :account_id, :digest ], unique: true, name: "idx_apple_verification_images_identity"
    add_index :apple_verification_images, [ :account_id, :name, :status ], name: "idx_apple_verification_images_catalog"

    reversible do |dir|
      dir.up do
        safety_assured do
          execute <<~SQL
            ALTER TABLE apple_verification_images ENABLE ROW LEVEL SECURITY;
            ALTER TABLE apple_verification_images FORCE ROW LEVEL SECURITY;
            CREATE POLICY tenant_isolation ON apple_verification_images
              USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
              WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
          SQL
        end
      end

      dir.down do
        safety_assured do
          execute "DROP POLICY IF EXISTS tenant_isolation ON apple_verification_images"
          execute "ALTER TABLE apple_verification_images NO FORCE ROW LEVEL SECURITY"
          execute "ALTER TABLE apple_verification_images DISABLE ROW LEVEL SECURITY"
        end
      end
    end
  end
end
