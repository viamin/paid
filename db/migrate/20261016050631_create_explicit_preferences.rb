class CreateExplicitPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :explicit_preferences,
      comment: "Explicit user statements retained for their confirmed scope; never inferred from interaction data." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade },
        comment: "Tenant that owns this preference."
      t.references :user, null: false, foreign_key: { on_delete: :cascade },
        comment: "User whose explicit preference this is."
      t.references :recorded_by, null: false, foreign_key: { to_table: :users, on_delete: :restrict },
        comment: "Collaborator who confirmed the statement and scope."
      t.references :project, foreign_key: { on_delete: :cascade },
        comment: "Project target when the user explicitly chose project or feature scope."
      t.references :feature_intent, foreign_key: { on_delete: :cascade },
        comment: "Feature target when the user explicitly chose feature scope."
      t.references :chat_session, foreign_key: { on_delete: :nullify },
        comment: "Exploration conversation that supplied the statement, when applicable."
      t.string :scope, null: false, limit: 20,
        comment: "Confirmed scope: user, project, or feature."
      t.text :statement, null: false,
        comment: "Verbatim explicit preference statement supplied by the user."

      t.timestamps
    end

    add_index :explicit_preferences, [ :account_id, :user_id, :scope ]
    add_index :explicit_preferences, [ :project_id, :scope ]
    add_check_constraint :explicit_preferences,
      "scope IN ('user', 'project', 'feature')",
      name: "explicit_preferences_scope"

    safety_assured do
      execute <<~SQL
        ALTER TABLE explicit_preferences ENABLE ROW LEVEL SECURITY;
        ALTER TABLE explicit_preferences FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON explicit_preferences
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (explicit_preferences.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (explicit_preferences.account_id = paid_current_account_id()));
      SQL
    end
  end
end
