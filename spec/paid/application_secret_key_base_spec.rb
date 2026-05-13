# frozen_string_literal: true

require "rails_helper"

RSpec.describe Paid::Application, :no_db do
  it "treats blank CI secrets as absent when resolving the test secret key base" do
    expect(Rails.application.secret_key_base).to eq(
      ENV["SECRET_KEY_BASE"].presence ||
      ENV["RAILS_TEST_KEY"].presence ||
      "test-secret-key-base"
    )
  end
end
