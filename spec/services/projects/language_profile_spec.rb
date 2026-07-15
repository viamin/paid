# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::LanguageProfile do
  describe ".label_for" do
    it "maps Ruby to the Rails project type" do
      expect(described_class.label_for("Ruby")).to eq("Ruby on Rails")
    end

    it "maps Elixir to the Phoenix project type" do
      expect(described_class.label_for("Elixir")).to eq("Phoenix / Elixir")
    end

    it "maps Swift to the macOS project type" do
      expect(described_class.label_for("Swift")).to eq("macOS / Swift")
    end

    it "is case-insensitive" do
      expect(described_class.label_for("rUbY")).to eq("Ruby on Rails")
    end

    it "ignores surrounding whitespace" do
      expect(described_class.label_for("  Ruby  ")).to eq("Ruby on Rails")
    end

    it "returns nil for unknown languages" do
      expect(described_class.label_for("Brainfuck")).to be_nil
    end

    it "returns nil for a blank language" do
      expect(described_class.label_for(nil)).to be_nil
      expect(described_class.label_for("")).to be_nil
      expect(described_class.label_for("   ")).to be_nil
    end
  end
end
