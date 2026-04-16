# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::ReviewRequest do
  it "captures pending users and teams separately" do
    req = described_class.new(users: [ "alice" ], teams: [ "reviewers" ])
    expect(req.users).to contain_exactly("alice")
    expect(req.teams).to contain_exactly("reviewers")
  end
end
