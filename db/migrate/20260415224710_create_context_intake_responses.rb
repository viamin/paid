class CreateContextIntakeResponses < ActiveRecord::Migration[8.1]
  def change
    create_table :context_intake_responses do |t|
      t.references :context_intake_session, null: false, foreign_key: true
      t.string :question_key, limit: 200, null: false
      t.text :question_text, null: false
      t.text :answer_text
      t.jsonb :answer_data, default: {}
      t.string :section, limit: 100, null: false
      t.integer :sequence, null: false, default: 0
      t.boolean :is_follow_up, default: false
      t.references :parent_response, null: true, foreign_key: { to_table: :context_intake_responses }
      t.boolean :skipped, default: false
      t.string :provenance, limit: 50, default: "human"

      t.timestamps
    end

    add_index :context_intake_responses,
      [:context_intake_session_id, :question_key],
      unique: true,
      name: "idx_context_intake_responses_session_question"
    add_index :context_intake_responses,
      [:context_intake_session_id, :section, :sequence],
      name: "idx_context_intake_responses_session_section_seq"
  end
end
