# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::RepoProfile do
  describe ".normalize" do
    it "normalizes persisted repo profile values" do
      profile = described_class.normalize(
        {
          "languages" => [ " Ruby ", "typescript", "ruby" ],
          "test_languages" => [ "TypeScript" ],
          "framework" => "Next.js",
          "marker_files" => [ "Gemfile", "Gemfile" ]
        }
      )

      expect(profile).to eq(
        "languages" => %w[ruby typescript],
        "test_languages" => %w[typescript],
        "framework" => "nextjs",
        "marker_files" => %w[Gemfile]
      )
    end

    it "falls back to the project primary language when none are persisted" do
      profile = described_class.normalize({}, primary_language: "Elixir")

      expect(profile["languages"]).to eq(%w[elixir])
      expect(profile["test_languages"]).to eq(%w[elixir])
    end
  end
end
