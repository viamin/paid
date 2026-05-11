# frozen_string_literal: true

require "erb"
require "spec_helper"

class DatabaseYmlErb
end

RSpec.describe DatabaseYmlErb do
  it "evaluates from the app root without relying on require_relative semantics" do
    rendered = Dir.chdir(File.expand_path("../..", __dir__)) do
      ERB.new(File.read("config/database.yml")).result
    end

    expect(rendered).to include("database: paid_development")
    expect(rendered).to include("database: paid_development_cable")
    expect(rendered).to include("database: paid_test")
  end
end
