# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "development:pg_hero_overview_scan rake task" do # rubocop:disable RSpec/DescribeClass
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("development:pg_hero_overview_scan")
  end

  # @spec RAILS-CONTROL-PLANE-026
  it "uses the same scheduled job path as the recurring scan" do
    allow(PgHeroOverviewScanJob).to receive(:perform_now).and_return(nil)

    Rake.application.invoke_task("development:pg_hero_overview_scan")

    expect(PgHeroOverviewScanJob).to have_received(:perform_now)
  end

  it "is defined with a description documenting the manual verification path" do
    rake_source = Rails.root.join("lib/tasks/development_pghero.rake").read

    expect(rake_source).to include("desc \"Scan the development PgHero Overview")
    expect(rake_source).to include("PgHeroOverviewScanJob.perform_now")
  end
end
