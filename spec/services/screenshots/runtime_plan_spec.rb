# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::RuntimePlan, :no_db do
  it "prefers the persisted project framework over filesystem redetection" do # @spec POLYGLOT-TEST-002
    Dir.mktmpdir do |repo_path|
      File.write(File.join(repo_path, "package.json"), JSON.dump({ "dependencies" => { "next" => "15.0.0" } }))

      project = instance_double(Project, detected_framework: "phoenix")
      config = instance_double(
        Screenshots::Configuration,
        setup_commands: [],
        base_url: "http://localhost:4000"
      )

      plan = described_class.call(project:, repo_path:, config:)

      expect(plan.framework).to eq(:phoenix)
    end
  end
end
