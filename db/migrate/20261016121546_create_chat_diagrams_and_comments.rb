# frozen_string_literal: true

class CreateChatDiagramsAndComments < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_diagrams, comment: "Typed, temporary diagrams rendered in chat" do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :chat_message, foreign_key: true, comment: "Optional transcript message that introduced the diagram"
      t.string :question_key, null: false, comment: "Stable question identity supplied with the diagram"
      t.string :question_title, null: false, comment: "Human-readable question shown with the diagram"
      t.text :summary, null: false, comment: "Short collapsed-card summary"
      t.text :text_equivalent, null: false, comment: "Accessible textual equivalent of the diagram"
      t.jsonb :description, null: false, default: {}, comment: "Validated element and relationship description"
      t.boolean :current, null: false, default: true, comment: "Whether this is the active diagram for its question"
      t.timestamps
    end
    add_index :chat_diagrams, %i[chat_session_id question_key], where: "current", unique: true,
      name: "index_chat_diagrams_one_current_per_question"

    create_table :chat_diagram_comments, comment: "Human comments with durable diagram context" do |t|
      t.references :chat_diagram, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }, comment: "User who made the comment"
      t.string :question_key, null: false, comment: "Question identity copied from the diagram"
      t.string :element_id, comment: "Selected element identity, if any"
      t.text :element_context, comment: "Selected element text copied at comment time"
      t.text :body, null: false
      t.timestamps
    end
    add_index :chat_diagram_comments, %i[chat_diagram_id created_at]

    reversible do |direction|
      direction.up { enable_tenant_rls }
    end
  end

  private

  def enable_tenant_rls
    safety_assured do
      execute <<~SQL
        ALTER TABLE chat_diagrams ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_diagrams FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_diagrams
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_diagrams.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR EXISTS (
              SELECT 1 FROM chat_sessions
              WHERE chat_sessions.id = chat_diagrams.chat_session_id
                AND chat_sessions.account_id = paid_current_account_id()
            )
          );
      SQL

      execute <<~SQL
        ALTER TABLE chat_diagram_comments ENABLE ROW LEVEL SECURITY;
        ALTER TABLE chat_diagram_comments FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON chat_diagram_comments
          AS PERMISSIVE FOR ALL
          USING (
            paid_tenant_bypass() OR (
              EXISTS (
                SELECT 1 FROM chat_diagrams
                INNER JOIN chat_sessions ON chat_sessions.id = chat_diagrams.chat_session_id
                WHERE chat_diagrams.id = chat_diagram_comments.chat_diagram_id
                  AND chat_sessions.account_id = paid_current_account_id()
              )
              AND EXISTS (
                SELECT 1 FROM users
                WHERE users.id = chat_diagram_comments.actor_id
                  AND users.account_id = paid_current_account_id()
              )
            )
          )
          WITH CHECK (
            paid_tenant_bypass() OR (
              EXISTS (
                SELECT 1 FROM chat_diagrams
                INNER JOIN chat_sessions ON chat_sessions.id = chat_diagrams.chat_session_id
                WHERE chat_diagrams.id = chat_diagram_comments.chat_diagram_id
                  AND chat_sessions.account_id = paid_current_account_id()
              )
              AND EXISTS (
                SELECT 1 FROM users
                WHERE users.id = chat_diagram_comments.actor_id
                  AND users.account_id = paid_current_account_id()
              )
            )
          );
      SQL
    end
  end
end
