# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128085541_remove_redundant_worktrees_project_id_index")

RSpec.describe RemoveRedundantWorktreesProjectIdIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  around do |example|
    migration.down
    example.run
  ensure
    migration.up
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes only the redundant project index while retaining the valid unique composite index", :aggregate_failures do
    migration.up

    expect(index("index_worktrees_on_project_id")).to be_nil
    expect(index("index_worktrees_on_project_id_and_branch_name")).to include(
      "indisvalid" => true,
      "indisunique" => true,
      "definition" => "CREATE UNIQUE INDEX index_worktrees_on_project_id_and_branch_name ON public.worktrees USING btree (project_id, branch_name)"
    )
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "restores the nonunique project index on rollback", :aggregate_failures do
    migration.up
    migration.down

    expect(index("index_worktrees_on_project_id")).to include(
      "indisvalid" => true,
      "indisunique" => false,
      "definition" => "CREATE INDEX index_worktrees_on_project_id ON public.worktrees USING btree (project_id)"
    )
  end

  private

  def index(name)
    connection.select_one(<<~SQL.squish)
      SELECT indisvalid, indisunique, pg_get_indexdef(indexrelid) AS definition
      FROM pg_index
      WHERE indexrelid = to_regclass(#{connection.quote(name)})
    SQL
  end
end
