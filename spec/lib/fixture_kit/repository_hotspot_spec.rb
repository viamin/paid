# frozen_string_literal: true

require "rails_helper"

# @spec TEST-SUITE-011
RSpec.describe FixtureKit::Repository do
  %w[activities/run_agent/base containers/provision/base].each do |name|
    context "with #{name}" do
      fixture name

      2.times do |index|
        it "starts example #{index + 1} with the original persisted graph" do
          repository = instance_variable_get(:@_fixture_kit_repository)
          project = repository.project

          expect(project.name).not_to eq("changed in an example")
          expect(project.created_by.name).not_to eq("changed in an example")
          expect(project.created_by.account).to eq(project.account)

          project.update!(name: "changed in an example")
          project.created_by.update!(name: "changed in an example")
        end
      end
    end
  end
end
