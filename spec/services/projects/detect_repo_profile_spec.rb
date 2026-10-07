# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::DetectRepoProfile, :no_db do
  let(:project) do
    instance_double(
      Project,
      primary_language: primary_language,
      effective_screenshot_settings: screenshot_settings
    )
  end
  let(:primary_language) { "Ruby" }
  let(:screenshot_settings) { {} }

  def with_repo
    Dir.mktmpdir do |repo_path|
      yield repo_path
    end
  end

  it "detects multiple repo languages and framework markers" do # @spec POLYGLOT-TEST-002
    with_repo do |repo_path|
      File.write(File.join(repo_path, "Gemfile"), "gem 'rails'\n")
      File.write(File.join(repo_path, "package.json"), JSON.dump({}))
      File.write(File.join(repo_path, "tsconfig.json"), JSON.dump({}))
      FileUtils.mkdir_p(File.join(repo_path, "config"))
      File.write(File.join(repo_path, "config/routes.rb"), "Rails.application.routes.draw {}\n")

      profile = described_class.call(project:, repo_path:)

      expect(profile["languages"]).to contain_exactly("ruby", "javascript", "typescript")
      expect(profile["test_languages"]).to contain_exactly("ruby", "javascript", "typescript")
      expect(profile["framework"]).to eq("rails")
      expect(profile["marker_files"]).to include("Gemfile", "package.json", "tsconfig.json")
    end
  end

  # @spec RDR-ROLLOUT-GUARD-003
  it "detects the FeatureFlags pattern only when its API is defined" do
    with_repo do |repo_path|
      FileUtils.mkdir_p(File.join(repo_path, "app/services"))
      File.write(File.join(repo_path, "Gemfile"), "gem 'rails'\n")
      File.write(File.join(repo_path, "app/services/feature_flags.rb"), <<~RUBY)
        class FeatureFlags
          DEFINITIONS = {}.freeze

          def self.enabled?(flag_name, project: nil)
          end
        end
      RUBY

      profile = described_class.call(project:, repo_path:)

      expect(profile["feature_flags_pattern"]).to be(true)
    end
  end

  # @spec RDR-ROLLOUT-GUARD-004
  it "does not infer the FeatureFlags pattern from Ruby or Rails alone" do
    with_repo do |repo_path|
      File.write(File.join(repo_path, "Gemfile"), "gem 'rails'\n")

      profile = described_class.call(project:, repo_path:)

      expect(profile).not_to have_key("feature_flags_pattern")
    end
  end

  it "applies .paid.yml overrides for languages, test languages, and framework" do # @spec POLYGLOT-TEST-002
    with_repo do |repo_path|
      File.write(File.join(repo_path, "mix.exs"), "defmodule Demo.MixProject do end\n")
      File.write(File.join(repo_path, ".paid.yml"), <<~YAML)
        languages:
          all:
            - elixir
            - javascript
          test:
            - elixir
        framework: phoenix
      YAML

      profile = described_class.call(project:, repo_path:)

      expect(profile["languages"]).to eq(%w[elixir javascript])
      expect(profile["test_languages"]).to eq(%w[elixir])
      expect(profile["framework"]).to eq("phoenix")
      expect(profile["manifest_path"]).to eq(".paid.yml")
    end
  end

  it "falls back to the primary language when repo markers are absent" do # @spec POLYGLOT-TEST-002
    with_repo do |repo_path|
      profile = described_class.call(project:, repo_path:)

      expect(profile["languages"]).to eq(%w[ruby])
      expect(profile["test_languages"]).to eq(%w[ruby])
    end
  end

  it "falls back to screenshot detection metadata when framework detection is generic" do # @spec POLYGLOT-TEST-002
    allow(project).to receive(:effective_screenshot_settings).and_return({ "detection" => { "framework" => "Phoenix" } })

    with_repo do |repo_path|
      File.write(File.join(repo_path, "README.md"), "hello\n")

      profile = described_class.call(project:, repo_path:)

      expect(profile["framework"]).to eq("phoenix")
    end
  end
end
