# frozen_string_literal: true

require "rails_helper"
require Rails.root.glob("db/migrate/*_remove_redundant_runner_credentials_account_runner_key_index.rb").sole

RSpec.describe RemoveRedundantRunnerCredentialsAccountRunnerKeyIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    add_legacy_index
    example.run
  ensure
    remove_legacy_index
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes the redundant lookup index, restores it on rollback, and retains the unique covering index" do
    described_class.new.up

    expect(index_named(described_class::INDEX_NAME)).to be_nil
    expect(covering_index).to have_attributes(
      columns: %w[account_id runner_key name],
      unique: true
    )

    described_class.new.down

    expect(index_named(described_class::INDEX_NAME)).to have_attributes(
      columns: %w[account_id runner_key],
      unique: false
    )
    expect(covering_index).to have_attributes(
      columns: %w[account_id runner_key name],
      unique: true
    )

    described_class.new.up

    expect(index_named(described_class::INDEX_NAME)).to be_nil
  end

  private

  def add_legacy_index
    return if index_named(described_class::INDEX_NAME)

    connection.add_index :runner_credentials, [ :account_id, :runner_key ],
      name: described_class::INDEX_NAME,
      algorithm: :concurrently
  end

  def remove_legacy_index
    return unless index_named(described_class::INDEX_NAME)

    connection.remove_index :runner_credentials,
      name: described_class::INDEX_NAME,
      algorithm: :concurrently
  end

  def index_named(name)
    connection.indexes(:runner_credentials).find { |index| index.name == name }
  end

  def covering_index
    index_named(described_class::COVERING_INDEX_NAME)
  end
end
