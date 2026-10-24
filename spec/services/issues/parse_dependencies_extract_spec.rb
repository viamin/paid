# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ParseDependencies, :no_db do
  describe ".extract" do
    # @spec DEPENDENCY-DECLARATIONS-001, DEPENDENCY-DECLARATIONS-002
    it "extracts bare dependency list items without treating following prose as dependencies" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          - #4263
          - [ ] #4268
          1. viamin/paid#4263

          Filed implementation tree: #4326 (umbrella), #4327–#4333 (planning and phases), #4334 (closeout).
        BODY
        comments: []
      )

      expect(local_deps).to eq(4263 => false, 4268 => false)
      expect(cross_deps).to eq([ "viamin", "paid", 4263 ] => false)
    end

    # @spec DEPENDENCY-DECLARATIONS-003
    it "keeps explicit inline and deployment directives in dependency-section prose" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          This work depends on #9043 and awaits deployment of owner/repo#9044.
          Implementation inventory: #9045.
        BODY
        comments: []
      )

      expect(local_deps).to eq(9043 => false)
      expect(cross_deps).to eq([ "owner", "repo", 9044 ] => true)
    end

    # @spec DEPENDENCY-DECLARATIONS-004
    it "ends bare-reference admission at a nested heading" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          - #9043

          ### Implementation Sub-Issues
          - [ ] #9044 (depends on #9043)
        BODY
        comments: []
      )

      expect(local_deps).to eq(9043 => false)
      expect(cross_deps).to eq({})
    end

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
