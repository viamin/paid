# frozen_string_literal: true

require "rails_helper"

class TemporalSdkDependencyContract < Pathname
end

RSpec.describe TemporalSdkDependencyContract, :no_db do
  # @spec TOOLCHAIN-PIN-055
  subject(:gemfile_source) { Rails.root.join("Gemfile").read }

  it "preserves the JSON 3 and MultiJson contracts required by the application" do
    expect(gemfile_source).to include('gem "json", "~> 3.1"')
    expect(gemfile_source).to include('gem "multi_json", ">= 1.21.2"')
  end

  it "rejects a Temporal SDK JSON requirement that excludes the application's JSON 3 range" do
    expect(json_3_compatible?("< 3")).to be(false)
  end

  it "loads a resolved Temporal SDK without a JSON requirement that excludes JSON 3" do
    json_dependency = Gem.loaded_specs.fetch("temporalio").runtime_dependencies.find { |dependency| dependency.name == "json" }

    expect(json_dependency).to be_nil.or satisfy { |dependency| json_3_compatible?(*dependency.requirement.requirements.map(&:join)) }
  end

  private

  def json_3_compatible?(*requirements)
    requirement = Gem::Requirement.new(*requirements)

    [ Gem::Version.new("3.1.0"), Gem::Version.new("3.99.0") ].all? { |version| requirement.satisfied_by?(version) }
  end
end
