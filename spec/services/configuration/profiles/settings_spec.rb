# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::Settings do
  describe ".normalize" do
    it "accepts explicit boolean override values" do
      expect(described_class.normalize("active", true)).to be(true)
      expect(described_class.normalize("active", false)).to be(false)
      expect(described_class.normalize("active", "true")).to be(true)
      expect(described_class.normalize("active", "false")).to be(false)
      expect(described_class.normalize("active", " 1 ")).to be(true)
      expect(described_class.normalize("active", " 0 ")).to be(false)
    end

    it "rejects ambiguous boolean-like strings" do
      expect {
        described_class.normalize("active", "foo")
      }.to raise_error(ArgumentError, /Invalid boolean override/)

      expect {
        described_class.normalize("active", "no")
      }.to raise_error(ArgumentError, /Invalid boolean override/)
    end

    it "strips GitHub login overrides" do
      expect(described_class.normalize("owner_reviewer_login", " octocat ")).to eq("octocat")
    end

    it "rejects non-string GitHub login overrides" do
      expect {
        described_class.normalize("owner_reviewer_login", { login: "octocat" })
      }.to raise_error(ArgumentError, /Invalid GitHub login override/)
    end

    it "normalizes enum overrides against the allowed values" do
      expect(described_class.normalize("auto_merge_mode", :all)).to eq("all")
      expect(described_class.normalize("merge_method", "rebase")).to eq("rebase")
    end

    it "rejects unknown enum overrides" do
      expect {
        described_class.normalize("auto_merge_mode", "sometimes")
      }.to raise_error(ArgumentError, /expected one of/)
    end
  end

  describe ".profile_target_keys" do
    it "returns the canonical operating-mode field list" do
      expect(described_class.profile_target_keys).to include(
        "auto_pick_enabled", "auto_merge_mode", "adoption_mode", "review_paid_agent", "review_manual", "quality_gate_enabled"
      )
      expect(described_class.profile_target_keys).not_to include("active", "owner_reviewer_login")
    end
  end

  describe ".read / .write" do
    let(:project) { create(:project) }

    it "round-trips boolean attributes" do
      described_class.write(project, "auto_pick_enabled", "true")
      project.save!

      expect(described_class.read(project.reload, "auto_pick_enabled")).to be true
    end

    it "round-trips enum attributes" do
      described_class.write(project, "auto_merge_mode", "all")
      described_class.write(project, "merge_method", "rebase")
      project.save!

      project.reload
      expect(described_class.read(project, "auto_merge_mode")).to eq("all")
      expect(described_class.read(project, "merge_method")).to eq("rebase")
    end

    it "round-trips adoption mode" do
      described_class.write(project, "adoption_mode", "full_execution")
      project.save!

      expect(described_class.read(project.reload, "adoption_mode")).to eq("full_execution")
    end

    it "keeps the top-level review toggle in sync with review methods" do
      described_class.write(project, "review_paid_agent", true)
      described_class.write(project, "review_copilot", false)

      expect(project.review_settings["enabled"]).to be true

      described_class.write(project, "review_paid_agent", false)

      expect(project.review_settings["enabled"]).to be false
    end

    it "keeps the top-level review toggle on while another review method remains enabled" do
      project.review_settings = {
        "enabled" => true,
        "methods" => {
          "manual" => { "enabled" => true, "reviewer_login" => "octocat" }
        }
      }

      described_class.write(project, "review_paid_agent", false)

      expect(project.review_settings["enabled"]).to be true
      expect(project.review_settings.dig("methods", "manual", "enabled")).to be true
    end

    it "round-trips the manual review flag" do
      described_class.write(project, "review_manual", true)
      project.save(validate: false)

      expect(described_class.read(project.reload, "review_manual")).to be true
    end

    it "syncs owner_reviewer_login into manual.reviewer_login when manual review is enabled" do
      project.update_columns(owner_reviewer_login: "octocat")

      described_class.write(project, "review_manual", true)

      expect(project.review_settings.dig("methods", "manual", "reviewer_login")).to eq("octocat")
    end

    it "preserves an existing manual.reviewer_login when manual review is disabled" do
      project.review_settings = {
        "enabled" => true,
        "methods" => {
          "manual" => { "enabled" => true, "reviewer_login" => "octocat" }
        }
      }

      described_class.write(project, "review_manual", false)

      expect(project.review_settings.dig("methods", "manual", "enabled")).to be false
      expect(project.review_settings.dig("methods", "manual", "reviewer_login")).to eq("octocat")
    end

    it "propagates a new owner_reviewer_login into manual.reviewer_login when manual review is on" do
      project.review_settings = {
        "enabled" => true,
        "methods" => {
          "manual" => { "enabled" => true, "reviewer_login" => nil }
        }
      }

      described_class.write(project, "owner_reviewer_login", "octocat")

      expect(project.review_settings.dig("methods", "manual", "reviewer_login")).to eq("octocat")
    end

    it "leaves manual.reviewer_login alone when manual review is disabled and the owner reviewer changes" do
      project.review_settings = {
        "enabled" => false,
        "methods" => {
          "manual" => { "enabled" => false, "reviewer_login" => "old-reviewer" }
        }
      }

      described_class.write(project, "owner_reviewer_login", "octocat")

      expect(project.review_settings.dig("methods", "manual", "reviewer_login")).to eq("old-reviewer")
    end

    it "round-trips the quality gate flag" do
      described_class.write(project, "quality_gate_enabled", true)
      project.save!

      expect(described_class.read(project.reload, "quality_gate_enabled")).to be true
    end
  end

  describe ".snapshot / .equivalent?" do
    it "reads every target field into a string-keyed hash" do
      snapshot = described_class.snapshot(create(:project, auto_pick_enabled: true))

      expect(snapshot.keys).to match_array(described_class.profile_target_keys)
      expect(snapshot["auto_pick_enabled"]).to be true
    end

    it "normalizes equivalent booleans and strings" do
      expect(described_class.equivalent?(true, "true")).to be true
      expect(described_class.equivalent?(false, "false")).to be true
      expect(described_class.equivalent?("off", "off")).to be true
      expect(described_class.equivalent?(true, false)).to be false
    end
  end
end
