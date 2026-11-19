# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PgHeroCleanHistoryJob", :no_db do
  # @spec RAILS-CONTROL-PLANE-021
  it "does not invoke PgHero outside development" do
    expect { PgHeroCleanHistoryJob.new.perform }.not_to raise_error
  end
end
