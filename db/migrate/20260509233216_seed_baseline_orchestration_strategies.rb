# frozen_string_literal: true

# No-op: this migration used to seed the baseline orchestration strategies by
# calling Strategies::SeedBaselineOrchestration.call, but any query against
# `strategies` or `strategy_versions` between 20260507211918 (RLS enabled,
# self-referencing policies) and 20260511040425 (recursion fix) raises
# "infinite recursion detected in policy for relation" — a structural
# consequence of the two tables' policies referencing each other, independent
# of the querying code. A from-scratch migration replay always hits this
# window, so the seeding was moved out of migration history entirely:
# `db/seeds.rb` and `bin/rails ci:bootstrap_test_defaults` now call
# Strategies::SeedBaselineOrchestration.call directly. See issue #3585.
#
# Databases that already applied this migration keep the rows it created;
# this file is kept only so schema_migrations history stays intact.
class SeedBaselineOrchestrationStrategies < ActiveRecord::Migration[8.1]
  def up; end

  def down; end
end
