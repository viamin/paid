# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261016220129_add_cancellation_details_to_feature_intents")

# @spec FEATURE-APPROVAL-020
RSpec.describe AddCancellationDetailsToFeatureIntents do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  it "removes its concurrent index on rollback so it can be reapplied" do
    migration.migrate(:down)

    expect(connection.index_exists?(:feature_intents, :cancelled_by_id)).to be(false)
    expect { migration.migrate(:up) }.not_to raise_error
    expect(connection.index_exists?(:feature_intents, :cancelled_by_id)).to be(true)
  ensure
    migration.migrate(:up)
  end
end
