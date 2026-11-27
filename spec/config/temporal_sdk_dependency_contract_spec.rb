# frozen_string_literal: true

require "rails_helper"
require "open3"
require "rbconfig"

class TemporalSdkDependencyContract < Pathname
end

RSpec.describe TemporalSdkDependencyContract, :no_db do
  # @spec TOOLCHAIN-PIN-055
  JSON_3_MINIMUM = Gem::Version.new("3.1").freeze
  JSON_3_MAXIMUM = Gem::Version.new("4").freeze

  subject(:gemfile_source) { Rails.root.join("Gemfile").read }

  it "preserves the JSON 3 and MultiJson contracts required by the application" do
    expect(gemfile_source).to include('gem "json", "~> 3.1"')
    expect(gemfile_source).to include('gem "multi_json", ">= 1.21.2"')
  end

  it "rejects a Temporal SDK JSON requirement that excludes the application's JSON 3 range" do
    expect(json_3_compatible?("< 3")).to be(false)
  end

  it "rejects a Temporal SDK JSON requirement with an exclusion in the application's JSON 3 range" do
    expect(json_3_compatible?(">= 3.1", "< 4", "!= 3.2.0")).to be(false)
  end

  it "accepts a Temporal SDK JSON requirement that contains the application's JSON 3 range" do
    expect(json_3_compatible?(">= 3.1", "< 4")).to be(true)
  end

  it "loads the selected Temporal client and Paid converter under the JSON 3 contract" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", client_and_converter_load_script)

    expect(status.success?).to be(true), stderr
    expect(stdout).to be_empty

    json_dependency = Gem.loaded_specs.fetch("temporalio").runtime_dependencies.find { |dependency| dependency.name == "json" }

    expect(json_dependency).to be_nil.or satisfy { |dependency| json_3_compatible?(*dependency.requirement.requirements.map(&:join)) }
  end

  private

  def json_3_compatible?(*requirements)
    Gem::Requirement.new(*requirements).requirements.none? do |operator, version|
      excludes_json_3_range?(operator, version)
    end
  end

  def excludes_json_3_range?(operator, version)
    case operator
    when "=" then true
    when "!=" then json_3_version?(version)
    when ">" then version >= JSON_3_MINIMUM
    when ">=" then version > JSON_3_MINIMUM
    when "<", "<=" then version < JSON_3_MAXIMUM
    when "~>" then version > JSON_3_MINIMUM || pessimistic_upper_bound(version) < JSON_3_MAXIMUM
    else raise ArgumentError, "unsupported JSON dependency operator: #{operator}"
    end
  end

  def json_3_version?(version)
    version >= JSON_3_MINIMUM && version < JSON_3_MAXIMUM
  end

  def pessimistic_upper_bound(version)
    segments = version.segments.dup
    segments.pop unless segments.one?
    segments[-1] += 1
    Gem::Version.new(segments.join("."))
  end

  def client_and_converter_load_script
    <<~RUBY
      require "bundler/setup"
      require "temporalio/client"
      require "paid/temporal_data_converter"
      Paid::TemporalDataConverter.new
    RUBY
  end
end
