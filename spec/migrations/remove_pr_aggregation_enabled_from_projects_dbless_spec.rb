# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260903034209_remove_pr_aggregation_enabled_from_projects")

RSpec.describe RemovePrAggregationEnabledFromProjects, :no_db do
  let(:migration) { described_class.new }

  describe "#up" do
    it "is a no-op (compatibility release keeps the column for one release)" do
      allow(migration).to receive(:remove_column)

      migration.up

      expect(migration).not_to have_received(:remove_column)
    end
  end

  describe "#down" do
    it "is a no-op (the column was not dropped, so rollback has nothing to recreate)" do
      allow(migration).to receive(:add_column)

      migration.down

      expect(migration).not_to have_received(:add_column)
    end
  end
end
