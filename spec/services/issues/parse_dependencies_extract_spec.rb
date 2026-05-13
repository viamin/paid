# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ParseDependencies, :no_db do
  describe ".extract" do
    it "uses issue.body when body is not passed explicitly" do
      issue = Data.define(:body).new("Depends on #9043")

      local_deps, cross_deps = described_class.new(issue: issue, comments: []).extract

      expect(local_deps).to eq(9043 => false)
      expect(cross_deps).to eq({})
    end
  end
end
