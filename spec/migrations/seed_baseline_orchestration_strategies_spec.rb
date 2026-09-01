# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260509233216_seed_baseline_orchestration_strategies")

# Regression test for #3585: this migration ran between the migration that
# enabled RLS on strategies/strategy_versions with self-referencing policies
# and the migration that fixed the resulting infinite recursion. Any query
# against either table in that window raises
# "infinite recursion detected in policy for relation", regardless of how the
# query is issued, so this migration must never touch those tables again.
# Baseline strategies are now seeded by db/seeds.rb and
# bin/rails ci:bootstrap_test_defaults instead.
RSpec.describe SeedBaselineOrchestrationStrategies do
  let(:migration) { described_class.new }

  it "does not create any strategies on #up" do
    expect { migration.up }.not_to change(Strategy, :count)
    expect { migration.up }.not_to change(StrategyVersion, :count)
  end

  it "does not destroy any strategies on #down" do
    Strategies::SeedBaselineOrchestration.call

    expect { migration.down }.not_to change(Strategy, :count)
    expect { migration.down }.not_to change(StrategyVersion, :count)
  end
end
