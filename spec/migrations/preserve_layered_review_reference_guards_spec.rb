# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117060031_preserve_layered_review_reference_guards")

RSpec.describe PreserveLayeredReviewReferenceGuards do
  # @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
  it "retains the current main FX guards when the corrective migration is replayed" do
    before = trigger_definitions
    expect(before.size).to eq(2)

    expect { ActiveRecord::Migration.suppress_messages { described_class.new.up } }.not_to raise_error

    expect(trigger_definitions).to eq(before)
  end

  # @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
  it "retains current guard enforcement on corrective rollback" do
    before = trigger_definitions

    ActiveRecord::Migration.suppress_messages { described_class.new.down }

    expect(trigger_definitions).to eq(before)
  end

  def trigger_definitions
    ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT pg_get_triggerdef(oid) FROM pg_trigger
      WHERE tgname IN ('enforce_layered_review_package_references', 'enforce_layered_review_approval_actor')
      ORDER BY tgname
    SQL
  end
end
