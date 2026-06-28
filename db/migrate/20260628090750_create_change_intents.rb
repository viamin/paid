# frozen_string_literal: true

class CreateChangeIntents < ActiveRecord::Migration[8.1]
  def change
    create_table :change_intents, comment: "Change Intent Records that capture human direction given to agents." do |t|
      t.references :project, null: false, foreign_key: true,
        comment: "Project the Change Intent Record belongs to."
      t.references :chat_session, foreign_key: true,
        comment: "Chat session where the intent was captured."
      t.references :issue, foreign_key: true,
        comment: "Optional issue the intent relates to."
      t.text :title, null: false,
        comment: "Short, human-readable title for the change intent."
      t.text :intent, null: false,
        comment: "What the human was trying to accomplish."
      t.text :behavior,
        comment: "Expected behavior or examples that clarify the intent."
      t.text :constraints,
        comment: "Non-obvious implementation boundaries or requirements."
      t.text :decisions_made,
        comment: "Rejected alternatives or decisions that shaped the approach."
      t.string :status, null: false, default: "draft",
        comment: "Lifecycle state: draft, active, superseded, or reverted."
      t.references :superseded_by, foreign_key: { to_table: :change_intents },
        comment: "Newer Change Intent Record that superseded this one."

      t.timestamps
    end

    add_index :change_intents, [ :project_id, :status ]
  end
end
