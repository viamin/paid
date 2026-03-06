# frozen_string_literal: true

require "rails_helper"

RSpec.describe StyleGuides::DetectLanguage do
  describe ".call" do
    it "detects Ruby from content" do
      content = "Use frozen_string_literal. Always use rubocop. Follow rails conventions. Use attr_reader."
      expect(described_class.call(content: content)).to eq("ruby")
    end

    it "detects JavaScript from content" do
      content = "Use const and let instead of var. Configure eslint. Use npm for packages. Prefer arrow functions with =>."
      expect(described_class.call(content: content)).to eq("javascript")
    end

    it "detects Python from content" do
      content = "Use def for functions. Configure flake8 and mypy. Use pip for packages. Always type self."
      expect(described_class.call(content: content)).to eq("python")
    end

    it "detects Go from content" do
      content = "Use func for functions. Run golangci-lint. Use goroutine for concurrency. Define struct types."
      expect(described_class.call(content: content)).to eq("go")
    end

    it "detects Rust from content" do
      content = "Use fn for functions. Run cargo clippy. Mark unsafe blocks. Use impl for implementations."
      expect(described_class.call(content: content)).to eq("rust")
    end

    it "returns nil for unrecognizable content" do
      content = "This is a general document with no programming language indicators."
      expect(described_class.call(content: content)).to be_nil
    end

    it "returns nil for empty content" do
      expect(described_class.call(content: "")).to be_nil
    end

    it "is case-insensitive" do
      content = "Use DEF for functions. Configure RUBOCOP. Follow RAILS conventions."
      expect(described_class.call(content: content)).to eq("ruby")
    end

    it "matches non-word indicators like =>" do
      content = "Use => for arrow functions. Use const and let. Configure eslint and prettier."
      result = described_class.call(content: content)
      expect(result).to eq("javascript")
    end

    it "returns nil when multiple languages tie for the top score" do
      content = "define an interface for the api"
      expect(described_class.call(content: content)).to be_nil
    end
  end
end
