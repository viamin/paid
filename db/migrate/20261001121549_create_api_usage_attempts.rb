# frozen_string_literal: true

class CreateApiUsageAttempts < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:api_usage_attempts)

    create_table :api_usage_attempts, comment: "Idempotent accounting reports for individual API provider requests." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :agent_run, null: true, foreign_key: { on_delete: :cascade }
      t.references :chat_session, null: true, foreign_key: { on_delete: :cascade }
      t.references :chat_message, null: true, foreign_key: { on_delete: :nullify }
      t.references :actor, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :runner, null: true, foreign_key: { on_delete: :nullify }
      t.references :token_usage, null: true, foreign_key: { on_delete: :nullify }
      t.string :attempt_id, null: false, limit: 255, comment: "Harness-generated stable physical request identity."
      t.integer :ordinal, null: false, comment: "Harness retry ordinal within the logical request."
      t.string :provider, null: false, limit: 100
      t.string :llm_model, limit: 100
      t.string :status, null: false, limit: 20
      t.integer :input_tokens, comment: "Nil means the provider did not report input usage."
      t.integer :output_tokens, comment: "Nil means the provider did not report output usage."
      t.integer :cache_read_tokens, comment: "Provider-reported cached input tokens, when available."
      t.integer :cache_write_tokens, comment: "Provider-reported cache creation tokens, when available."
      t.decimal :provider_cost_amount, precision: 20, scale: 8, comment: "Raw provider charge in provider_currency."
      t.string :provider_currency, limit: 3, comment: "ISO 4217 currency for the raw provider charge."
      t.string :pricing_source, null: false, default: "unknown", limit: 30
      t.datetime :provider_priced_at, comment: "Provider or historical-pricing timestamp."
      t.datetime :started_at, null: false
      t.datetime :finished_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :api_usage_attempts, [ :attempt_id, :ordinal ], unique: true, name: "idx_api_usage_attempts_idempotency"
    add_index :api_usage_attempts, [ :account_id, :created_at ], name: "idx_api_usage_attempts_account_created"
    add_index :api_usage_attempts, [ :project_id, :created_at ], name: "idx_api_usage_attempts_project_created"
    add_check_constraint :api_usage_attempts,
      "((agent_run_id IS NOT NULL)::int + (chat_session_id IS NOT NULL)::int) = 1",
      name: "api_usage_attempts_exactly_one_owner"
    %w[input output cache_read cache_write].each do |kind|
      add_check_constraint :api_usage_attempts, "#{kind}_tokens IS NULL OR #{kind}_tokens >= 0",
        name: "api_usage_attempts_#{kind}_tokens_nonnegative"
    end

    safety_assured do
      execute "ALTER TABLE api_usage_attempts ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE api_usage_attempts FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON api_usage_attempts
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR account_id = paid_current_account_id())
          WITH CHECK (paid_tenant_bypass() OR account_id = paid_current_account_id());
      SQL
    end
  end

  def down
    return unless table_exists?(:api_usage_attempts)

    safety_assured { drop_table :api_usage_attempts }
  end
end
