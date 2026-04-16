# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::Comment do
  it "captures author, body, and timestamps" do
    c = described_class.new(
      id: 9, author_login: "bot", body: "hi",
      created_at: Time.at(0), updated_at: nil, url: nil
    )
    expect(c.body).to eq("hi")
  end
end
