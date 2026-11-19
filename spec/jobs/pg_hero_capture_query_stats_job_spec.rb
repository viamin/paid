# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PgHeroCaptureQueryStatsJob", :no_db do
  # @spec RAILS-CONTROL-PLANE-020
  it "does not invoke PgHero outside development" do
    expect { PgHeroCaptureQueryStatsJob.new.perform }.not_to raise_error
  end

  # @spec RAILS-CONTROL-PLANE-022
  it "does not configure an immediate retry loop" do
    expect(PgHeroCaptureQueryStatsJob.max_attempts).to eq(1)
  end
end
