# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe ReleasePlease::ParseReleasePr do
  def build_pr_data(title:, author: "github-actions[bot]", labels: [ "autorelease: pending" ], number: 42)
    OpenStruct.new(
      number: number,
      title: title,
      user: OpenStruct.new(login: author),
      labels: labels.map { |name| OpenStruct.new(name: name) }
    )
  end

  describe ".call" do
    it "parses a valid release-please PR and classifies a minor bump" do
      pr = build_pr_data(title: "chore(main): release 1.2.0")
      result = described_class.call(pr_data: pr, previous_version: "1.1.0")

      expect(result).to be_present
      expect(result.pr_number).to eq(42)
      expect(result.new_version).to eq("1.2.0")
      expect(result.previous_version).to eq("1.1.0")
      expect(result.bump).to eq("minor")
    end

    it "classifies a major bump" do
      pr = build_pr_data(title: "chore(main): release 2.0.0")
      result = described_class.call(pr_data: pr, previous_version: "1.5.3")

      expect(result.bump).to eq("major")
    end

    it "classifies a patch bump" do
      pr = build_pr_data(title: "chore(main): release 1.2.3")
      result = described_class.call(pr_data: pr, previous_version: "1.2.2")

      expect(result.bump).to eq("patch")
    end

    it "handles 0.x versioning with literal semver positions" do
      pr = build_pr_data(title: "chore(main): release 0.23.0")
      result = described_class.call(pr_data: pr, previous_version: "0.22.0")

      expect(result.bump).to eq("minor")
    end

    it "returns nil for non-release-please authors" do
      pr = build_pr_data(title: "chore(main): release 1.0.0", author: "some-user")
      result = described_class.call(pr_data: pr, previous_version: "0.9.0")

      expect(result).to be_nil
    end

    it "returns nil when title does not match release-please format" do
      pr = build_pr_data(title: "fix: some bug")
      result = described_class.call(pr_data: pr, previous_version: "1.0.0")

      expect(result).to be_nil
    end

    it "returns nil when autorelease: pending label is missing" do
      pr = build_pr_data(title: "chore(main): release 1.1.0", labels: [ "some-label" ])
      result = described_class.call(pr_data: pr, previous_version: "1.0.0")

      expect(result).to be_nil
    end

    it "returns nil when previous_version is blank" do
      pr = build_pr_data(title: "chore(main): release 1.0.0")
      result = described_class.call(pr_data: pr, previous_version: nil)

      expect(result).to be_nil
    end

    it "accepts release-please[bot] as author" do
      pr = build_pr_data(title: "chore(main): release 1.1.0", author: "release-please[bot]")
      result = described_class.call(pr_data: pr, previous_version: "1.0.0")

      expect(result).to be_present
      expect(result.bump).to eq("minor")
    end

    it "returns nil when versions are equal" do
      pr = build_pr_data(title: "chore(main): release 1.0.0")
      result = described_class.call(pr_data: pr, previous_version: "1.0.0")

      expect(result).to be_nil
    end
  end

  describe ".release_please_pr?" do
    it "returns true for valid release-please PRs" do
      pr = build_pr_data(title: "chore(main): release 1.0.0")
      expect(described_class.release_please_pr?(pr)).to be true
    end

    it "returns false for non-release-please PRs" do
      pr = build_pr_data(title: "feat: add feature", author: "developer")
      expect(described_class.release_please_pr?(pr)).to be false
    end
  end
end
