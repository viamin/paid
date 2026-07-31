# frozen_string_literal: true

class CreateStrategiesAndStrategyVersions < ActiveRecord::Migration[8.1]
  def up
    create_table :strategies, comment: "Scoped orchestration strategies selected for workflow decisions." do |t|
      t.string :slug,
        null: false,
        limit: 100,
        comment: "Stable identifier used to resolve a strategy within its scope."
      t.string :name,
        null: false,
        limit: 255,
        comment: "Human-readable strategy name."
      t.text :description,
        comment: "Optional description of when and why this strategy should be selected."
      t.string :decision_type,
        null: false,
        limit: 100,
        comment: "Workflow decision boundary this strategy governs, such as issue_execution or retry."
      t.string :status,
        null: false,
        limit: 20,
        default: "active",
        comment: "Lifecycle state controlling whether the strategy is eligible for selection."
      t.jsonb :selection_rules,
        null: false,
        default: {},
        comment: "Structured scope and context rules used to select the strategy."
      t.references :account,
        null: true,
        foreign_key: { on_delete: :cascade },
        comment: "Owning account for account-scoped and project-scoped strategies."
      t.references :project,
        null: true,
        foreign_key: { on_delete: :cascade },
        comment: "Owning project for project-specific strategy overrides."
      t.bigint :current_version_id,
        null: true,
        comment: "Currently promoted strategy version used by selection."

      t.timestamps
    end

    add_index :strategies, :current_version_id
    add_index :strategies, :decision_type
    add_index :strategies, :status
    add_index :strategies, [ :decision_type, :status ], name: "index_strategies_on_decision_type_and_status"
    add_index :strategies, :slug, unique: true,
      where: "account_id IS NULL AND project_id IS NULL",
      name: "index_strategies_on_slug_global"
    add_index :strategies, [ :slug, :account_id ], unique: true,
      where: "account_id IS NOT NULL AND project_id IS NULL",
      name: "index_strategies_on_slug_account"
    add_index :strategies, [ :slug, :project_id ], unique: true,
      where: "project_id IS NOT NULL",
      name: "index_strategies_on_slug_project"
    add_check_constraint :strategies,
      "(project_id IS NULL OR account_id IS NOT NULL)",
      name: "chk_strategies_scope_consistency"

    create_table :strategy_versions, comment: "Versioned orchestration strategy payloads and promotion history." do |t|
      t.references :strategy,
        null: false,
        foreign_key: { on_delete: :cascade },
        comment: "Parent strategy whose behavior this version defines."
      t.integer :version,
        null: false,
        comment: "Monotonic version number within a strategy."
      t.jsonb :content,
        null: false,
        default: {},
        comment: "Structured orchestration behavior moved out of hardcoded workflow logic."
      t.jsonb :provenance,
        null: false,
        default: {},
        comment: "Origin metadata such as manual creation, evolution run, or experiment lineage."
      t.string :promotion_state,
        null: false,
        limit: 20,
        default: "draft",
        comment: "Promotion lifecycle state for this version."
      t.text :reasoning,
        comment: "Why this version exists or differs from its parent."
      t.text :change_notes,
        comment: "Operator- or workflow-authored notes about the change."
      t.string :created_by,
        limit: 50,
        comment: "Origin label such as seed, human, or evolution."
      t.references :created_by_user,
        null: true,
        foreign_key: { to_table: :users, on_delete: :nullify },
        comment: "User who created the version when applicable."
      t.references :parent_version,
        null: true,
        foreign_key: { to_table: :strategy_versions, on_delete: :nullify },
        comment: "Previous version this candidate was derived from."
      t.references :promoted_by_user,
        null: true,
        foreign_key: { to_table: :users, on_delete: :nullify },
        comment: "User who promoted this version to current."
      t.datetime :promoted_at,
        comment: "When this version became current."
      t.datetime :retired_at,
        comment: "When this version stopped being eligible for execution."

      t.timestamps
    end

    add_index :strategy_versions, [ :strategy_id, :version ], unique: true
    add_index :strategy_versions, [ :strategy_id, :promotion_state ],
      name: "index_strategy_versions_on_strategy_and_promotion_state"
    add_index :strategy_versions, :retired_at
    add_index :strategy_versions, :strategy_id,
      unique: true,
      where: "promotion_state = 'active' AND retired_at IS NULL",
      name: "index_strategy_versions_one_active_per_strategy"

    safety_assured do
      execute <<~SQL
        ALTER TABLE strategies
          ADD CONSTRAINT fk_strategies_account_id
          FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE,
          ADD CONSTRAINT fk_strategies_project_id
          FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
          ADD CONSTRAINT fk_strategies_current_version_id
          FOREIGN KEY (current_version_id) REFERENCES strategy_versions(id) ON DELETE SET NULL
      SQL

      execute <<~SQL
        ALTER TABLE strategy_versions
          ADD CONSTRAINT fk_strategy_versions_strategy_id
          FOREIGN KEY (strategy_id) REFERENCES strategies(id) ON DELETE CASCADE,
          ADD CONSTRAINT fk_strategy_versions_created_by_user_id
          FOREIGN KEY (created_by_user_id) REFERENCES users(id) ON DELETE SET NULL,
          ADD CONSTRAINT fk_strategy_versions_parent_version_id
          FOREIGN KEY (parent_version_id) REFERENCES strategy_versions(id) ON DELETE SET NULL,
          ADD CONSTRAINT fk_strategy_versions_promoted_by_user_id
          FOREIGN KEY (promoted_by_user_id) REFERENCES users(id) ON DELETE SET NULL
      SQL
    end
  end

  def down
    if table_exists?(:orchestration_decisions) && column_exists?(:orchestration_decisions, :strategy_version_id)
      safety_assured do
        execute "DROP TRIGGER IF EXISTS validate_strategy_version_scope ON orchestration_decisions"
        execute "DROP FUNCTION IF EXISTS validate_orchestration_decision_strategy_version_scope()"
        remove_foreign_key :orchestration_decisions, column: :strategy_version_id if foreign_key_exists?(:orchestration_decisions, :strategy_versions, column: :strategy_version_id)
        remove_index :orchestration_decisions, :strategy_version_id if index_exists?(:orchestration_decisions, :strategy_version_id)
        remove_column :orchestration_decisions, :strategy_version_id
      end
    end

    remove_foreign_key :strategies, column: :current_version_id if table_exists?(:strategies) && foreign_key_exists?(:strategies, :strategy_versions, column: :current_version_id)
    drop_table :strategy_versions, if_exists: true
    drop_table :strategies, if_exists: true
  end
end
