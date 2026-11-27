# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261127193520_validate_projects_git_push_fallback_token_foreign_key")

RSpec.describe ValidateProjectsGitPushFallbackTokenForeignKey do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  def reference
    connection.foreign_keys(:projects).find { |key| key.column == "git_push_fallback_token_id" }
  end

  around do |example|
    original = reference
    connection.remove_foreign_key :projects, column: :git_push_fallback_token_id
    connection.add_foreign_key :projects, :github_tokens,
      column: :git_push_fallback_token_id, name: original.name, validate: false
    connection.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  ensure
    connection.validate_foreign_key :projects, :github_tokens,
      column: :git_push_fallback_token_id if original&.validated?
  end

  # @spec POSTGRESQL-PERSISTENCE-016
  it "validates existing references without changing their definition or rows" do
    original = reference.to_h
    count = connection.select_value("SELECT COUNT(*) FROM projects")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(reference).to be_validated
    expect(reference.to_h).to eq(original.merge(options: original.fetch(:options).merge(validate: true)))
    expect(connection.select_value("SELECT COUNT(*) FROM projects")).to eq(count)
  end

  # @spec POSTGRESQL-PERSISTENCE-016
  it "preserves validation and the foreign key on rollback" do
    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:up)
      migration.migrate(:down)
    end
    expect(reference).to be_validated
  end
end
