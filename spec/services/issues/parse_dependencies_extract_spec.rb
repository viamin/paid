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

    # @spec DEPENDENCY-DECLARATIONS-001
    it "ignores indented code-block examples that resemble dependency list items" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
              - #4326
          - #41
        BODY
        comments: []
      )

      expect(local_deps).to eq(41 => false)
      expect(cross_deps).to eq({})
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

    # @spec DEPENDENCY-DECLARATIONS-001, DEPENDENCY-DECLARATIONS-006
    it "extracts refs folded into list-item continuation lines" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          - #41,
            #42
          - [ ] Awaits work on
                owner/repo#43
        BODY
        comments: []
      )

      expect(local_deps).to eq(41 => false, 42 => false)
      expect(cross_deps).to eq([ "owner", "repo", 43 ] => false)
    end

    # @spec DEPENDENCY-DECLARATIONS-007
    it "ignores list-style lines inside fenced code blocks in a dependency section" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          Declaration style to avoid:

          ```text
          - #4326
          ```

          ~~~
          - #4327
          ~~~

          - #41
        BODY
        comments: []
      )

      expect(local_deps).to eq(41 => false)
      expect(cross_deps).to eq({})
    end

    # @spec DEPENDENCY-DECLARATIONS-007
    it "keeps a fenced block open when it contains a different fence delimiter" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          ```text
          ~~~
          - #4326
          ```
        BODY
        comments: []
      )

      expect(local_deps).to eq({})
      expect(cross_deps).to eq({})
    end

    # @spec DEPENDENCY-DECLARATIONS-007
    it "requires a closing fence at least as long as its opening fence" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          ````text
          - #4326
          ```
          - #4327
          ````

          - #41
        BODY
        comments: []
      )

      expect(local_deps).to eq(41 => false)
      expect(cross_deps).to eq({})
    end

    # @spec DEPENDENCY-DECLARATIONS-002, DEPENDENCY-DECLARATIONS-006
    it "does not admit indented prose that follows no list item" do
      local_deps, _cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          Filed implementation tree:
            #4326 (umbrella), #4327–#4333 (phases)
        BODY
        comments: []
      )

      expect(local_deps).to eq({})
    end

    # @spec DEPENDENCY-DECLARATIONS-006
    it "requires continuation lines to reach the list item's content indentation" do
      local_deps, cross_deps = described_class.extract(
        body: <<~BODY,
          ## Dependencies
          - #41
           #42
          1. #43
           #44
          - #45
            #46
          1. #47
             #48
        BODY
        comments: []
      )

      expect(local_deps).to eq(41 => false, 43 => false, 45 => false, 46 => false, 47 => false, 48 => false)
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
