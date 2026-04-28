# frozen_string_literal: true

class AddChatSessionToTokenUsages < ActiveRecord::Migration[8.1]
  def change
    add_column :token_usages, :chat_session_id, :bigint, null: true

    add_index :token_usages, :chat_session_id

    add_foreign_key :token_usages, :chat_sessions

    # Replace the old exactly-one-run constraint with a new one that allows
    # exactly one of agent_run, knowledge_run, or chat_session.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          ALTER TABLE token_usages DROP CONSTRAINT IF EXISTS token_usages_exactly_one_run;
          ALTER TABLE token_usages ADD CONSTRAINT token_usages_exactly_one_run CHECK (
            (
              (agent_run_id IS NOT NULL)::int +
              (knowledge_run_id IS NOT NULL)::int +
              (chat_session_id IS NOT NULL)::int
            ) = 1
          );
        SQL
      end

      dir.down do
        execute <<~SQL
          ALTER TABLE token_usages DROP CONSTRAINT IF EXISTS token_usages_exactly_one_run;
          ALTER TABLE token_usages ADD CONSTRAINT token_usages_exactly_one_run CHECK (
            (agent_run_id IS NOT NULL) <> (knowledge_run_id IS NOT NULL)
          );
        SQL
      end
    end
  end
end
