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

    it "ignores inline non-dependency phrases while keeping real dependencies" do
      local_deps, cross_deps = described_class.extract(
        body: "Depends on #9043. Independent of #9044. Not blocked by deployment of #9045.",
        comments: []
      )

      expect(local_deps).to eq(9043 => false)
      expect(cross_deps).to eq({})
    end

    it "ignores non-dependency phrases inside a dependencies section" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          - #9043
          - No dependency on #9044
          - Not blocked by deployment of owner/repo#9045
        BODY
        comments: []
      )

      expect(local_deps).to eq(9043 => false)
      expect(cross_deps).to eq({})
    end
  end
end
