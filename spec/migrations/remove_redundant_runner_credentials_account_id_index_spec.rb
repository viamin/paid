# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128105817_remove_redundant_runner_credentials_account_id_index")

RSpec.describe RemoveRedundantRunnerCredentialsAccountIdIndex do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    index_existed = index_exists?(described_class::INDEX_NAME)
    connection.add_index :runner_credentials, :account_id, name: described_class::INDEX_NAME unless index_existed

    example.run
  ensure
    if index_existed
      connection.add_index :runner_credentials, :account_id, name: described_class::INDEX_NAME unless index_exists?(described_class::INDEX_NAME)
    else
      connection.remove_index :runner_credentials, name: described_class::INDEX_NAME, if_exists: true
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes the redundant index, restores it on rollback, and removes it on reapplication" do
    expect(index_exists?(described_class::INDEX_NAME)).to be(true)
    expect(index_exists?(described_class::COVERING_INDEX_NAME)).to be(true)

    described_class.new.up

    expect(index_exists?(described_class::INDEX_NAME)).to be(false)
    expect(index_exists?(described_class::COVERING_INDEX_NAME)).to be(true)

    described_class.new.down

    expect(index_exists?(described_class::INDEX_NAME)).to be(true)
    expect(index_exists?(described_class::COVERING_INDEX_NAME)).to be(true)

    described_class.new.up

    expect(index_exists?(described_class::INDEX_NAME)).to be(false)
    expect(index_exists?(described_class::COVERING_INDEX_NAME)).to be(true)
  end

  private

  def index_exists?(name)
    connection.index_exists?(:runner_credentials, name:)
  end
end
