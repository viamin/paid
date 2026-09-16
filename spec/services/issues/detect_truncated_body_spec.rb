# frozen_string_literal: true

require "rails_helper"

# @spec ISSUE-ANALYSIS-015
RSpec.describe Issues::DetectTruncatedBody do
  describe ".call" do
    it "flags a body cut off mid-sentence with no terminal punctuation" do
      body = <<~BODY
        Dot notation is central to YupYup ergonomics, but it should not force
        Rubys naming convention on every consumer. We need a way to opt out
        for specific keys while keeping the ergonomics for everything else
        that does not force Rubys
      BODY

      expect(described_class.call(body)).to be(true)
    end

    it "flags a body that ends inside an unterminated code fence" do
      body = <<~BODY
        Here is the proposed API:

        ```ruby
        def call(value)
          value.to_s
      BODY

      expect(described_class.call(body)).to be(true)
    end

    it "flags a body that ends with a dangling heading and no content" do
      body = <<~BODY
        We should add retry support for the sync job when the upstream API
        rate-limits requests, mirroring the backoff already used elsewhere.

        ## Proposed changes
      BODY

      expect(described_class.call(body)).to be(true)
    end

    it "does not flag a well-formed body ending in a normal sentence" do
      body = <<~BODY
        The dashboard currently shows stale counts when a job fails midway
        through. This is confusing to operators who expect the count to
        reflect the latest successful run.
      BODY

      expect(described_class.call(body)).to be(false)
    end

    it "does not flag a body ending with a terminated code block" do
      body = <<~BODY
        Here is the proposed API:

        ```ruby
        def call(value)
          value.to_s
        end
        ```
      BODY

      expect(described_class.call(body)).to be(false)
    end

    it "does not flag a body ending with a list item" do
      body = <<~BODY
        We need to support a few additional formats:

        - CSV export
        - JSON export
        - YAML export
      BODY

      expect(described_class.call(body)).to be(false)
    end

    it "does not flag a body ending with a numbered list item" do
      body = <<~BODY
        The steps to reproduce are as follows and each one matters a lot:

        1. Open the dashboard
        2. Click the export button
      BODY

      expect(described_class.call(body)).to be(false)
    end

    it "does not flag a short body without terminal punctuation" do
      expect(described_class.call("Fix typo in README")).to be(false)
    end

    it "does not flag a blank body" do
      expect(described_class.call(nil)).to be(false)
      expect(described_class.call("")).to be(false)
    end

    it "does not flag a body ending with a closing bracket or quote" do
      body = <<~BODY
        The config currently reads the value from `ENV["FOO"]` and this has
        caused confusion because the surrounding docs describe it as `"foo"`
      BODY

      expect(described_class.call(body)).to be(false)
    end
  end
end
