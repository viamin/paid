# frozen_string_literal: true

class CreateClarifyingQuestionProgresses < ActiveRecord::Migration[8.1]
  def change
    create_table :clarifying_question_progresses,
      comment: "Durable per-question exploration progress and attributable answer evidence." do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true
      t.references :chat_session, null: false, foreign_key: true
      t.text :question, null: false, comment: "The exact pending-question text this progress addresses."
      t.string :question_digest, null: false, comment: "Digest of the ordered question set that produced this record."
      t.integer :position, null: false, comment: "One-based question position within the digested question set."
      t.text :answer, comment: "Latest draft or final human answer; nil means unresolved."
      t.text :evidence_context, comment: "Human-readable context retained when temporary exploration material is removed."
      t.string :design_claim, comment: "Optional canonical design claim identifier supported by this answer."
      t.references :answered_by, foreign_key: { to_table: :users }
      t.datetime :answered_at, comment: "When the latest answer was explicitly recorded."

      t.timestamps
    end

    add_index :clarifying_question_progresses, [ :issue_id, :question_digest, :position ],
      unique: true, name: "index_clarifying_question_progresses_identity"
  end
end
