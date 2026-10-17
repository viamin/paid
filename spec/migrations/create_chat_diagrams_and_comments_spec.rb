# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261016121546_create_chat_diagrams_and_comments")

RSpec.describe CreateChatDiagramsAndComments, :no_db do
  # @spec QUESTION-EXPLORATION-007
  let(:migration) { described_class.new }

  before do
    allow(migration).to receive(:create_table)
    allow(migration).to receive(:add_index)
  end

  it "enables forced tenant RLS for diagrams and their comments" do
    recorded_sql = []
    allow(migration).to receive(:execute) { |sql| recorded_sql << sql }

    migration.migrate(:up)

    sql = recorded_sql.join("\n")
    expect(sql).to include("ALTER TABLE chat_diagrams ENABLE ROW LEVEL SECURITY;")
    expect(sql).to include("ALTER TABLE chat_diagrams FORCE ROW LEVEL SECURITY;")
    expect(sql).to include("CREATE POLICY tenant_isolation ON chat_diagrams")
    expect(sql).to include("chat_sessions.account_id = paid_current_account_id()")
    expect(sql).to include("ALTER TABLE chat_diagram_comments ENABLE ROW LEVEL SECURITY;")
    expect(sql).to include("ALTER TABLE chat_diagram_comments FORCE ROW LEVEL SECURITY;")
    expect(sql).to include("CREATE POLICY tenant_isolation ON chat_diagram_comments")
    expect(sql).to include("chat_diagrams.id = chat_diagram_comments.chat_diagram_id")
  end
end
