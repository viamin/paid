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

  describe "parse_rails_routes_output" do
    it "extracts the URI path (after the verb) from rails routes output" do
      output = <<~ROUTES
                         Prefix Verb   URI Pattern                 Controller#Action
                           root GET    /                           home#index
                      dashboard GET    /dashboard(.:format)        dashboard#show
                        reports GET    /reports(.:format)          reports#index
                   edit_profile GET    /profile/edit(.:format)     profiles#edit
      ROUTES

      service = described_class.new(repo_path: fixture_path("rails_repo"))
      routes = service.send(:parse_rails_routes_output, output)
      paths = routes.map { |r| r["path"] }

      expect(paths).to include("/", "/dashboard", "/reports", "/profile/edit")
      expect(paths).not_to include("root", "dashboard", "reports", "edit_profile")
    end

    it "handles lines where the prefix column is blank" do
      output = <<~ROUTES
                         Prefix Verb   URI Pattern                 Controller#Action
                                POST   /sessions(.:format)         sessions#create
                        sign_in GET    /sign_in(.:format)          sessions#new
      ROUTES

      service = described_class.new(repo_path: fixture_path("rails_repo"))
      routes = service.send(:parse_rails_routes_output, output)
      paths = routes.map { |r| r["path"] }

      expect(paths).to include("/sessions", "/sign_in")
    end
  end

  describe "dependency memoization" do
    let(:repo) do
      instance_double(
        described_class::LocalRepository,
        file?: false,
        directory?: false,
        glob: [],
        paths: []
      )
    end

    before do
      allow(repo).to receive(:read).with("Gemfile").and_return("gem 'rails'\ngem 'devise'\n")
      allow(repo).to receive(:read).with("package.json").and_return(JSON.dump({
        "dependencies" => { "next" => "1.0.0", "next-auth" => "1.0.0", "redis" => "1.0.0" }
      }))
      allow(repo).to receive(:read).with("config/database.yml").and_return("")
      allow(repo).to receive(:read).with("config/routes.rb").and_return("devise_for :users\n")
      allow(repo).to receive(:read).with("middleware.ts").and_return("")
      allow(repo).to receive(:read).with("middleware.js").and_return("")
    end

    it "reads Gemfile and package.json once even when multiple detectors query dependencies" do
      service = described_class.new(repo_path: fixture_path("generic_repo"))
      allow(service).to receive(:repo).and_return(repo)

      service.send(:detect_rails)
      service.send(:detect_nextjs)
      service.send(:detect_services)

      expect(repo).to have_received(:read).with("Gemfile").once
      expect(repo).to have_received(:read).with("package.json").once
    end
  end
end
