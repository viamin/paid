# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::Registry do
  describe "registry mechanics" do
    # config/initializers/configuration_profiles.rb populates the real
    # registry at boot; isolate these examples from that state so they only
    # exercise register/find/summaries behavior.
    around do |example|
      original_profiles = described_class.all.dup
      described_class.reset!
      example.run
    ensure
      described_class.reset!
      original_profiles.each { |profile| described_class.register(profile) }
    end

    let(:profile_a) { class_double(ConfigurationProfiles::Profile, id: "profile_a") }
    let(:profile_b) { class_double(ConfigurationProfiles::Profile, id: "profile_b") }

    describe ".register" do
      it "adds a profile to the registry" do
        described_class.register(profile_a)

        expect(described_class.all).to eq([ profile_a ])
      end

      it "does not register the same profile twice" do
        described_class.register(profile_a)
        described_class.register(profile_a)

        expect(described_class.all).to eq([ profile_a ])
      end
    end

    describe ".find" do
      before do
        described_class.register(profile_a)
        described_class.register(profile_b)
      end

      it "finds a profile by string or symbol id" do
        expect(described_class.find("profile_a")).to eq(profile_a)
        expect(described_class.find(:profile_b)).to eq(profile_b)
      end

      it "returns nil when no profile matches" do
        expect(described_class.find("missing")).to be_nil
      end
    end

    describe ".summaries" do
      it "maps registered profiles to their .summary" do
        summary = { id: "profile_a", name: "Profile A" }
        allow(profile_a).to receive(:summary).and_return(summary)
        described_class.register(profile_a)

        expect(described_class.summaries).to eq([ summary ])
      end
    end
  end

  describe "the real registrations from the initializer" do
    it "includes the solo_fully_automated and team_collaborative profiles" do
      expect(described_class.find("solo_fully_automated")).to eq(ConfigurationProfiles::SoloFullyAutomatedProfile)
      expect(described_class.find("team_collaborative")).to eq(ConfigurationProfiles::TeamCollaborativeProfile)
    end
  end
end
