# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::DetectRepoProfile do
  it "routes polyglot commands and image resolution from detect_repo_profile output" do # @spec POLYGLOT-TEST-002 # @spec POLYGLOT-TEST-003 # @spec POLYGLOT-TEST-004
    project = create(:project, primary_language: "Ruby")

    Dir.mktmpdir do |repo_path|
      File.write(File.join(repo_path, "mix.exs"), <<~ELIXIR)
        defmodule Demo.MixProject do
          use Mix.Project
        end
      ELIXIR
      File.write(File.join(repo_path, "package.json"), JSON.dump({ "name" => "demo" }))

      profile = described_class.call(project:, repo_path:)
      project.update!(repo_profile: profile)
    end

    expect(project.reload.repo_profile).to include("languages" => %w[javascript elixir])
    expect(project.test_languages).to eq(%w[javascript elixir])
    expect(Prompts::LanguageCommands.test_commands_for(project)).to eq([ "npm test", "mix test" ])
    expect(Containers::ImageResolver.resolve(project)).to eq("paid-agent:elixir-node")
  end
end
