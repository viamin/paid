# frozen_string_literal: true

# Creates the immutable agent image registry records required by
# RDR-059. Each row represents a single (account, registry, repository,
# digest, architecture) identity, the canonical Docker content-addressed
# tuple. Once persisted, the identity fields are immutable and the row
# is retained for audit and rollback even when the image is deprecated
# or blocked.
class CreateAgentImages < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_images,
      comment: "Immutable registry of agent container images identified by (registry, repository, digest, architecture) and tracked through active/deprecated/blocked states for audit, scheduling, and rollback." do |t|
      t.references :account, null: false, foreign_key: true,
        comment: "Account that owns the image registry record. Image identity is scoped per account so different accounts can record the same upstream digest independently."
      t.string :name, null: false,
        comment: "Logical image profile name (e.g. base, elixir-node, ruby) used for ImageResolver / scheduling decisions."
      t.string :tag, null: false,
        comment: "Docker tag that produced this image (e.g. latest, ruby-3.3.0). Mutable on the registry but immutable once recorded against a digest."
      t.string :registry, null: false, default: "docker.io",
        comment: "OCI registry host the image was pulled from (docker.io, ghcr.io, registry.example.test). docker.io is the implicit default."
      t.string :repository, null: false,
        comment: "OCI repository path within the registry (e.g. paid-agent, paid-agent-extra, organization/paid-agent)."
      t.string :digest, null: false,
        comment: "Immutable content-addressed identity, accepted as sha256:<64-hex> or 64-hex characters. The digest is the production source of truth for what image runs."
      t.string :architecture, null: false, default: "amd64",
        comment: "Target architecture of this image (amd64, arm64, 386, arm, ppc64le, s390x). The same digest on a different architecture is a separate image record."
      t.jsonb :provenance, null: false, default: {},
        comment: "Build provenance such as the GitHub Actions run id, repository, ref, and commit SHA that produced the image. Mutable for late-arriving provenance updates."
      t.jsonb :metadata, null: false, default: {},
        comment: "Extensible observability and operations metadata (build log URL, runbook link, signing identity). Mutable without affecting the image identity."
      t.datetime :built_at, null: false,
        comment: "Wall-clock time the image was built or pushed upstream, recorded by the build pipeline."
      t.string :status, null: false, default: "active",
        comment: "Lifecycle state: active (schedulable), deprecated (still runnable but superseded), or blocked (excluded from future scheduling)."
      t.datetime :deprecated_at,
        comment: "Timestamp the image was transitioned to deprecated. Preserved for historical queries; not the same as blocked."
      t.text :deprecation_reason,
        comment: "Free-text reason captured when the image was deprecated (e.g. the successor image reference)."
      t.datetime :blocked_at,
        comment: "Timestamp the image was transitioned to blocked. Distinct from deprecated: blocked images cannot be scheduled even if they are still installed."
      t.text :blocked_reason,
        comment: "Free-text reason captured when the image was blocked (e.g. CVE identifier and severity)."

      t.timestamps
    end

    # The immutable production identity. Two rows must never share the
    # same content-addressed identity inside one account, so any future
    # rebuild still produces a brand-new row.
    add_index :agent_images,
      [ :account_id, :registry, :repository, :digest, :architecture ],
      unique: true,
      name: "idx_agent_images_identity",
      comment: "Uniqueness over the immutable content-addressed identity (account + registry + repository + digest + architecture)."

    # Scheduling and lookup index: which image is available for a given
    # (account, profile, architecture). Status filtering rides on top of
    # this index via a WHERE clause, since strong_migrations discourages
    # non-unique indexes with more than three columns.
    add_index :agent_images,
      [ :account_id, :name, :architecture ],
      name: "idx_agent_images_profile_arch",
      comment: "Lookup index for scheduling and image-resolver queries that need the current image for a (profile, architecture) within an account."

    add_index :agent_images, :status,
      where: "status <> 'active'",
      name: "idx_agent_images_inactive",
      comment: "Partial index over non-active images so audit and rollback queries against deprecated/blocked rows stay fast as the active set grows."

    reversible do |dir|
      dir.up do
        safety_assured do
          execute <<~SQL
            ALTER TABLE agent_images ENABLE ROW LEVEL SECURITY;
            ALTER TABLE agent_images FORCE ROW LEVEL SECURITY;
            CREATE POLICY tenant_isolation ON agent_images
              USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
              WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
          SQL
        end
      end

      dir.down do
        safety_assured do
          execute "DROP POLICY IF EXISTS tenant_isolation ON agent_images"
          execute "ALTER TABLE agent_images NO FORCE ROW LEVEL SECURITY"
          execute "ALTER TABLE agent_images DISABLE ROW LEVEL SECURITY"
        end
      end
    end
  end
end
