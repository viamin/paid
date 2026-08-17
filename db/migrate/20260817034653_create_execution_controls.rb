# frozen_string_literal: true

class CreateExecutionControls < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:execution_controls)

    create_table :execution_controls, comment: "Execution disable controls for global, account, project, runner, and backend scopes." do |t|
      t.string :scope, null: false, comment: "Scope controlled by this row: global, account, project, runner, or backend."
      t.references :account, foreign_key: true, comment: "Account target when scope=account."
      t.references :project, foreign_key: true, comment: "Project target when scope=project."
      t.references :runner, foreign_key: true, comment: "Runner target when scope=runner."
      t.references :docker_host, foreign_key: true, comment: "Docker host target when scope=backend."
      t.boolean :enabled, null: false, default: false, comment: "Whether new execution is currently disabled for the scope."
      t.string :mode, null: false, default: "capacity", comment: "Disable mode: emergency cancels active runs; capacity parks them."
      t.text :reason, comment: "Operator-supplied reason for the current disable state."
      t.jsonb :metadata, null: false, default: {}, comment: "Structured metadata for audit context and affected-run tracking."
      t.datetime :enabled_at, comment: "When the control last became active."
      t.datetime :disabled_at, comment: "When the control was last cleared."
      t.timestamps
    end

    add_index :execution_controls, :scope
    add_index :execution_controls, :enabled
    add_index :execution_controls, :account_id, unique: true, where: "scope = 'account'", name: "idx_execution_controls_account_scope"
    add_index :execution_controls, :project_id, unique: true, where: "scope = 'project'", name: "idx_execution_controls_project_scope"
    add_index :execution_controls, :runner_id, unique: true, where: "scope = 'runner'", name: "idx_execution_controls_runner_scope"
    add_index :execution_controls, :docker_host_id, unique: true, where: "scope = 'backend'", name: "idx_execution_controls_backend_scope"
    add_index :execution_controls, :scope, unique: true, where: "scope = 'global'", name: "idx_execution_controls_global_scope_singleton"
  end
end
