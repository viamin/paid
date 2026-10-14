# frozen_string_literal: true

require "rails_helper"
require "test_prof/recipes/rspec/let_it_be"

# @spec TEST-SUITE-011
RSpec.describe TestProf::LetItBe do
  [ "with stable agent execution project", "with stable provisioning project" ].each do |name|
    context name do
      include_context name

      2.times do |index|
        it "starts example #{index + 1} with the original persisted graph" do
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
