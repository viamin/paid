# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-READINESS-008 PROJECT-READINESS-012
RSpec.describe Projects::Readiness::BootstrapWriteGuard do
  describe ".call" do
    it "allows Godot CI, harness, and test layout artifacts" do
      result = described_class.call(changed_files: [
        ".github/workflows/gdunit.yml", "project.godot", "addons/gdUnit4/plugin.cfg", "tests/.gitkeep"
      ])

      expect(result).to be_valid
      expect(result.forbidden_files).to eq([])
    end

    it "allows each conventional test directory layout" do
      result = described_class.call(changed_files: [
        "spec/example_spec.rb", "test/example_test.rb", "tests/example_test.py",
        "__tests__/example.test.js", "Tests/ExampleTests.swift"
      ])

      expect(result).to be_valid
      expect(result.forbidden_files).to eq([])
    end

    it "allows the verification configuration needed by a bootstrap repair" do
      result = described_class.call(changed_files: [ ".paid/screenshots.yml" ])

      expect(result).to be_valid
    end

    it "rejects behavior-bearing files outside the harness class" do
      result = described_class.call(changed_files: [ ".github/workflows/gdunit.yml", "scripts/player.gd" ])

      expect(result).not_to be_valid
      expect(result.forbidden_files).to eq([ "scripts/player.gd" ])
      expect(result.reason).to eq("bootstrap runs may only change harness configuration and test layout")
    end
  end
end
