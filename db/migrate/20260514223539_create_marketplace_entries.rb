# frozen_string_literal: true

class CreateMarketplaceEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_entries, comment: "Team-shareable agent enhancements that can be attached to agent runs" do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false, limit: 255
      t.string :entry_type, null: false, limit: 50, comment: "Logical enhancement category such as skill, plugin, or MCP server."
      t.text :description
      t.string :provider, limit: 100, comment: "Primary target runtime or provider family for this entry."
      t.string :provider_format, null: false, default: "canonical_v1", limit: 100, comment: "Default artifact schema or provider-native format identifier."
      t.text :usage_guidance, comment: "Human guidance describing when the entry should be used."
      t.string :added_by_name, null: false, limit: 255
      t.string :added_by_email, null: false, limit: 255
      t.jsonb :tags, null: false, default: [], comment: "Searchable labels for browsing and matching."
      t.string :team_scope, null: false, default: "account", limit: 50, comment: "Marketplace visibility scope within the tenant."
      t.string :status, null: false, default: "draft", limit: 50, comment: "Lifecycle state for safe rollout and deprecation."
      t.timestamps
    end

    create_table :marketplace_entry_versions, comment: "Immutable provider-content snapshots for marketplace entries" do |t|
      t.references :marketplace_entry, null: false, foreign_key: true
      t.integer :version, null: false, default: 1
      t.text :changelog
      t.jsonb :canonical_artifact, null: false, default: {}, comment: "Canonical runtime artifact preserved for rendering into provider-specific payloads."
      t.jsonb :renderers, null: false, default: {}, comment: "Provider-specific renderers or native payload snapshots keyed by provider."
      t.jsonb :compatibility_constraints, null: false, default: {}, comment: "Provider, model, runtime, or tool constraints for attachment."
      t.jsonb :review_metadata, null: false, default: {}, comment: "Optional approval and review metadata for the version."
      t.timestamps
    end

    create_table :marketplace_entry_rules, comment: "Account-scoped rules for auto-attaching or defaulting marketplace entries" do |t|
      t.references :marketplace_entry, null: false, foreign_key: true
      t.string :mode, null: false, limit: 50, comment: "Whether the rule is automatic matching or a team default."
      t.boolean :enabled, null: false, default: true
      t.integer :position, null: false, default: 0
      t.text :rationale
      t.jsonb :conditions, null: false, default: {}, comment: "Run-context conditions that must match before the entry attaches."
      t.timestamps
    end

    create_table :agent_run_marketplace_entries, comment: "Marketplace entries attached to a specific agent run with rendered provider payloads" do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.references :marketplace_entry, null: false, foreign_key: true
      t.references :marketplace_entry_version, null: false, foreign_key: true
      t.string :attachment_source, null: false, limit: 50, comment: "Whether the attachment came from manual selection, a team default, or automatic matching."
      t.integer :position, null: false, default: 0
      t.text :selection_reason
      t.string :rendered_format, null: false, default: "canonical_v1", limit: 100, comment: "Exact provider-facing format emitted for this run."
      t.jsonb :rendered_payload, null: false, default: {}, comment: "Resolved provider-facing payload snapshot used by this run."
      t.timestamps
    end

    add_reference :marketplace_entries,
      :current_version,
      foreign_key: { to_table: :marketplace_entry_versions },
      comment: "Current active content snapshot for this marketplace entry."

    add_index :marketplace_entries, [ :account_id, :entry_type, :status ]
    add_index :marketplace_entries, [ :account_id, :team_scope, :status ]
    add_index :marketplace_entries, :tags, using: :gin
    add_index :marketplace_entry_versions, [ :marketplace_entry_id, :version ], unique: true,
      name: "index_marketplace_entry_versions_unique_version"
    add_index :marketplace_entry_rules, [ :marketplace_entry_id, :mode, :position ],
      name: "index_marketplace_entry_rules_on_entry_mode_position"
    add_index :agent_run_marketplace_entries, [ :agent_run_id, :marketplace_entry_id ], unique: true,
      name: "index_agent_run_marketplace_entries_unique_attachment"
    add_index :agent_run_marketplace_entries, [ :agent_run_id, :attachment_source, :position ],
      name: "index_agent_run_marketplace_entries_on_run_source_position"
  end
end
