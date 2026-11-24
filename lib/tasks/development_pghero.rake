# frozen_string_literal: true

# Manual verification entry point for the development PgHero Overview scan.
# Performs the scheduled job so both paths share the collector, policy,
# persisted state, and issue filer.
#
# @spec RAILS-CONTROL-PLANE-026
namespace :development do
  desc "Scan the development PgHero Overview and file/update self-repo issues (same path as the scheduled job)"
  task pg_hero_overview_scan: :environment do
    PgHeroOverviewScanJob.perform_now
  end
end
