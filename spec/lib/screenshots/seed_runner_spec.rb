# frozen_string_literal: true

require "rails_helper"
require "screenshots/seed_runner"

RSpec.describe Screenshots::SeedRunner do
  let(:config) do
    Screenshots::Configuration.from_hash(
      "driver" => "cuprite",
      "routes" => [ { "path" => "/", "name" => "home" } ],
      "seed" => [
        {
          "key" => "__all__",
          "runner" => "{
            \"user\" => { \"id\" => 1, \"email\" => \"screenshot@example.com\", \"password\" => \"secret\" },
            \"project\" => { \"id\" => 2, \"name\" => \"Paid\" }
          }"
        }
      ]
    )
  end

  it "expands composite runner output into open structs keyed by seed name" do
    stdout = JSON.generate(
      "user" => { "id" => 1, "email" => "screenshot@example.com", "password" => "secret" },
      "project" => { "id" => 2, "name" => "Paid" }
    )
    allow(Open3).to receive(:capture3).and_return([ stdout, "", instance_double(Process::Status, success?: true) ])

    result = described_class.new.call(config:, repo_path: Rails.root.to_s, driver_name: "cuprite")

    expect(result[:user].email).to eq("screenshot@example.com")
    expect(result[:project].id).to eq(2)
  end

  it "skips seed execution for non-cuprite drivers" do
    result = described_class.new.call(config:, repo_path: Rails.root.to_s, driver_name: "playwright")

    expect(result).to eq({})
  end
end
