# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::DetectFramework do
  def fixture_path(name)
    Rails.root.join("spec/fixtures/screenshots/#{name}").to_s
  end

  describe ".call" do
    it "detects a Rails app and suggests a Cuprite config" do
      result = described_class.call(repo_path: fixture_path("rails_repo"))

      expect(result.framework).to eq(:rails)
      expect(result.confidence).to eq(1.0)
      expect(result.suggested_config["driver"]).to eq("cuprite")
      expect(result.detected_services).to contain_exactly("postgres", "redis")
      expect(result.suggested_config.dig("auth", "strategy")).to eq("form")
      expect(result.detected_routes.map { |route| route["path"] }).to include("/", "/dashboard", "/reports")
    end

    it "detects a Next.js app and discovers app routes" do
      result = described_class.call(repo_path: fixture_path("next_repo"))

      expect(result.framework).to eq(:nextjs)
      expect(result.confidence).to eq(1.0)
      expect(result.suggested_config["driver"]).to eq("playwright")
      expect(result.suggested_config.dig("auth", "strategy")).to eq("custom")
      expect(result.detected_routes.map { |route| route["path"] }).to include("/", "/dashboard", "/blog/:slug")
    end

    it "detects a Django app and parses urls.py routes" do
      result = described_class.call(repo_path: fixture_path("django_repo"))

      expect(result.framework).to eq(:django)
      expect(result.confidence).to eq(1.0)
      expect(result.suggested_config["base_url"]).to eq("http://localhost:8000")
      expect(result.detected_routes.map { |route| route["path"] }).to include("/", "/admin/", "/accounts/login/")
      expect(result.suggested_config.dig("auth", "login_path")).to eq("/accounts/login/")
    end

    it "falls back to a generic app when no known framework is detected" do
      result = described_class.call(repo_path: fixture_path("generic_repo"))

      expect(result.framework).to eq(:generic)
      expect(result.confidence).to eq(0.45)
      expect(result.suggested_config["driver"]).to eq("playwright")
      expect(result.detected_routes).to eq([])
      expect(result.suggested_yaml).to include("routes: []")
    end

    it "uses lower confidence when only generic frontend assets are present" do
      result = described_class.call(repo_path: fixture_path("generic_repo"))

      expect(result.confidence).to be < 0.5
    end
  end
end
