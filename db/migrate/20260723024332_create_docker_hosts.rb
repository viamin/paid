# frozen_string_literal: true

class CreateDockerHosts < ActiveRecord::Migration[8.1]
  def change
    create_table :docker_hosts,
      comment: "Persisted Docker backend targets and readiness metadata for account-level run placement." do |t|
      t.references :account, null: false, foreign_key: true, comment: "Account that owns and may place runs onto this Docker host."
      t.string :identifier, null: false, comment: "Stable host identifier persisted onto agent_runs.container_host for historical ownership."
      t.string :display_name, null: false, comment: "Operator-facing label shown in the account admin UI."
      t.string :backend_type, null: false, comment: "Docker backend type, such as local, remote, or swarm."
      t.string :endpoint, comment: "Docker daemon endpoint for remote hosts; blank for the local host."
      t.string :callback_url, comment: "Paid proxy callback URL that containers on this host must reach."
      t.string :image_tag, null: false, default: "paid-agent:latest", comment: "Expected agent image tag for readiness checks and setup guidance."
      t.boolean :enabled, null: false, default: true, comment: "Whether new manual or automatic placements may target this host."
      t.boolean :fallback_eligible, null: false, default: true, comment: "Whether first-healthy fallback may use this host when the preferred host is unavailable."
      t.integer :manual_concurrency_limit, null: false, default: 1, comment: "Independent host-level run cap enforced separately from account, user, and project guardrails."
      t.string :readiness_status, null: false, default: "unknown", comment: "Cached host readiness state shown in the admin control plane."
      t.string :failing_check, comment: "Named readiness check currently failing, if any."
      t.datetime :last_checked_at, comment: "Most recent readiness probe time."
      t.datetime :last_ready_at, comment: "Most recent successful readiness probe time."
      t.text :last_error, comment: "Last readiness or provisioning error surfaced to operators."
      t.string :daemon_architecture, comment: "Docker daemon architecture reported by readiness checks."
      t.string :daemon_summary, comment: "Short Docker daemon summary surfaced to operators."
      t.string :image_status, null: false, default: "unknown", comment: "Whether the required agent image is present and compatible."
      t.string :required_network_status, null: false, default: "unknown", comment: "Whether the required Docker network exists on the host."
      t.datetime :disabled_at, comment: "When the host was disabled for new placements while retaining historical ownership."
      t.jsonb :metadata, null: false, default: {}, comment: "Extensible host-scoped readiness and setup metadata."

      t.timestamps
    end

    add_index :docker_hosts, [ :account_id, :identifier ], unique: true
    add_index :docker_hosts, [ :account_id, :enabled ]
    add_index :docker_hosts, [ :account_id, :fallback_eligible ]
  end
end
