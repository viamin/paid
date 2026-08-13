# frozen_string_literal: true

class CreateChangeIntents < ActiveRecord::Migration[8.1]
  def change
    create_table :change_intents, comment: "Captures human directional intent that should persist in the knowledge base." do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade },
        comment: "Project this change intent applies to."
      t.references :chat_session, null: true, foreign_key: { on_delete: :nullify },
        comment: "Chat session where the intent was captured, when applicable."
      t.references :issue, null: true, foreign_key: { on_delete: :nullify },
        comment: "Issue that motivated or contextualized the intent, when applicable."
      t.text :title, null: false, comment: "Short title summarizing the intent."
      t.text :intent, null: false, comment: "What the human was trying to accomplish."
      t.text :behavior, comment: "Expected behavior, often captured as given/when/then scenarios."
      t.text :constraints, comment: "Boundaries and constraints that shaped the implementation."
      t.text :decisions_made, comment: "Alternatives that were rejected and why."
      t.bigint :superseded_by_id, comment: "Newer change intent that superseded this record."
      t.string :status, null: false, default: "draft", limit: 50,
        comment: "Lifecycle state for the record: draft, active, or superseded."

      t.timestamps
    end

    add_foreign_key :change_intents, :change_intents, column: :superseded_by_id, on_delete: :nullify, validate: false
    add_index :change_intents, [ :project_id, :status ]
    add_index :change_intents, :superseded_by_id
  end
end
