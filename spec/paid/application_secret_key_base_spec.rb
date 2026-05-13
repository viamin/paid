# frozen_string_literal: true

require "rails_helper"

RSpec.describe Paid::Application, :no_db do
  it "uses an explicit fallback when SECRET_KEY_BASE is unset" do
    expect(Rails.application.secret_key_base).to eq(
      ENV.fetch("SECRET_KEY_BASE", "test-secret-key-base")
    )
  end
end
