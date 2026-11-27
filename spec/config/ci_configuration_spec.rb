# frozen_string_literal: true

require "rails_helper"

class CiConfiguration < Pathname
end

RSpec.describe CiConfiguration, :no_db do
  # @spec TEST-SUITE-031
  it "runs the ApplicationJob queue inventory before expensive local verification" do
    configuration = Rails.root.join("config/ci.rb").read

    expect(configuration).to match(
      /step "ApplicationJob queue inventory".*spec\/config\/application_job_queue_priority_spec\.rb.*step "Lint".*step "Security audit"/m
    )
  end
end
