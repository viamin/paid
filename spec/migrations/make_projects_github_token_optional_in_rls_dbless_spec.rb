# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260730190357_make_projects_github_token_optional_in_rls")

RSpec.describe MakeProjectsGithubTokenOptionalInRls, :no_db do
  let(:migration) { described_class.new }

  let(:recorded_sql) do
    recorded = []
    allow(migration).to receive(:execute) { |sql| recorded << sql }
    migration.up
    recorded
  end

  it "drops the existing projects tenant_isolation policy before recreating it" do
    expect(recorded_sql.join("\n")).to include("DROP POLICY IF EXISTS tenant_isolation ON projects")
  end

  it "recreates the projects policy treating github_token_id as optional" do
    sql = recorded_sql.join("\n")

    expect(sql).to include("CREATE POLICY tenant_isolation ON projects")
    expect(sql).to include("projects.github_token_id IS NULL")
    # Both the read (USING) and write (WITH CHECK) clauses must tolerate a missing token.
    expect(sql.scan("projects.github_token_id IS NULL").length).to be >= 2
  end

  it "preserves account and creator ownership checks in the new policy" do
    sql = recorded_sql.join("\n")

    expect(sql).to include("projects.account_id = paid_current_account_id()")
    expect(sql).to include("projects.created_by_id IS NULL")
    expect(sql).to include("github_tokens.account_id = paid_current_account_id()")
  end
end
