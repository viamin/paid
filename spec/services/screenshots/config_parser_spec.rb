# frozen_string_literal: true

require "base64"
require "rails_helper"

RSpec.describe Screenshots::ConfigParser do
  def write_config(dir, content)
    FileUtils.mkdir_p(File.join(dir, ".paid"))
    File.write(File.join(dir, ".paid", "screenshots.yml"), content)
  end

  let(:repo_dir) { Dir.mktmpdir }
  let(:project) { build(:project) }

  after do
    FileUtils.rm_rf(repo_dir)
  end

  describe ".from_repo_path" do
    context "with a minimal config" do
      subject(:config) { described_class.from_repo_path(repo_dir, project: project) }

      before do
        write_config(repo_dir, <<~YAML)
          routes:
            - path: /
              name: homepage
        YAML
      end

      it "returns a frozen configuration object" do
        expect(config).to be_a(Screenshots::Configuration)
        expect(config).to be_frozen
      end

      it "applies top-level defaults" do
        expect(config.enabled?).to be false
        expect(config.driver).to eq("playwright")
        expect(config.base_url).to eq("http://localhost:3000")
      end

      it "applies viewport and auth defaults" do
        expect(config.viewport.width).to eq(1280)
        expect(config.viewport.height).to eq(900)
        expect(config.auth.strategy).to eq("none")
      end

      it "keeps the declared route and default UI globs" do
        expect(config.routes).to contain_exactly(
          have_attributes(path: "/", name: "homepage", requires_auth: false, seed_key: nil)
        )
        expect(config.ui_patterns).to eq(Screenshots::Configuration::DEFAULT_UI_PATTERNS)
        expect(config.ui_exclusions).to eq(Screenshots::Configuration::DEFAULT_UI_EXCLUSIONS)
      end
    end

    context "with a full config" do
      subject(:config) { described_class.from_repo_path(repo_dir, project: project) }

      before do
        write_config(repo_dir, <<~YAML)
          driver: cuprite
          base_url: http://localhost:4000
          viewport:
            width: 1440
            height: 960
          routes:
            - path: /
              name: homepage
            - path: /projects/:project_id
              name: project_show
              requires_auth: true
              seed_key: project
          auth:
            strategy: form
            login_path: /login
            fields:
              email: input[name="email"]
              password: input[name="password"]
              submit: button[type="submit"]
            credentials:
              email: admin@example.com
              password: password123
          seed:
            - model: User
              factory: admin
              key: user
            - model: Project
              factory: project
              key: project
              owner: user
          setup:
            - bin/rails db:prepare
            - bin/rails db:seed
          services:
            - postgres
            - redis
          ui_patterns:
            - app/views/**/*
            - app/components/**/*
          ui_exclusions:
            - app/views/layouts/mailer/**/*
        YAML
      end

      it "parses the driver, base url, and viewport" do
        expect(config.driver).to eq("cuprite")
        expect(config.base_url).to eq("http://localhost:4000")
        expect(config.viewport).to have_attributes(width: 1440, height: 960)
      end

      it "parses routes and auth" do
        expect(config.routes.last).to have_attributes(
          path: "/projects/:project_id",
          name: "project_show",
          requires_auth: true,
          seed_key: "project"
        )
        expect(config.auth).to have_attributes(strategy: "form", login_path: "/login")
        expect(config.auth.fields).to include("email" => 'input[name="email"]')
        expect(config.auth.credentials).to include("email" => "admin@example.com")
      end

      it "parses seed, setup, services, and UI globs" do
        expect(config.seed.last).to have_attributes(model: "Project", factory: "project", key: "project")
        expect(config.seed.last.attributes).to eq("owner" => "user")
        expect(config.setup).to eq([ "bin/rails db:prepare", "bin/rails db:seed" ])
        expect(config.services).to eq(%w[postgres redis])
        expect(config.ui_patterns).to eq([ "app/views/**/*", "app/components/**/*" ])
        expect(config.ui_exclusions).to eq([ "app/views/layouts/mailer/**/*" ])
      end
    end

    context "with project-level overrides" do
      subject(:config) { described_class.from_repo_path(repo_dir, project: project) }

      before do
        project.screenshot_settings = {
          "enabled" => true,
          "driver" => "cuprite",
          "auth" => { "strategy" => "token", "credentials" => { "token" => "db-token" } },
          "setup" => [ "bin/rails db:prepare" ]
        }

        write_config(repo_dir, <<~YAML)
          driver: playwright
          routes:
            - path: /dashboard
              name: dashboard
              requires_auth: true
          auth:
            strategy: form
            login_path: /login
            fields:
              email: input[name="email"]
              password: input[name="password"]
              submit: button[type="submit"]
          setup:
            - yarn build
        YAML
      end

      it "keeps enabled and driver from the database" do
        expect(config.enabled?).to be true
        expect(config.driver).to eq("cuprite")
      end

      it "uses repo-defined auth, routes, and setup" do
        expect(config.routes).to contain_exactly(have_attributes(name: "dashboard"))
        expect(config.auth.strategy).to eq("form")
        expect(config.auth.login_path).to eq("/login")
        expect(config.setup).to eq([ "yarn build" ])
      end
    end

    it "raises a helpful error for a missing config file" do
      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /Missing \.paid\/screenshots\.yml/)
    end

    it "rejects an invalid driver" do
      write_config(repo_dir, <<~YAML)
        driver: selenium
        routes:
          - path: /
            name: homepage
      YAML

      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /driver must be one of: playwright, cuprite/)
    end

    it "rejects empty routes" do
      write_config(repo_dir, <<~YAML)
        routes: []
      YAML

      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /routes must be a non-empty array/)
    end

    it "requires auth.fields when auth.strategy is form" do
      write_config(repo_dir, <<~YAML)
        routes:
          - path: /
            name: homepage
        auth:
          strategy: form
      YAML

      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /auth\.fields is required/)
    end

    it "rejects non-positive viewport values" do
      write_config(repo_dir, <<~YAML)
        viewport:
          width: 0
          height: 900
        routes:
          - path: /
            name: homepage
      YAML

      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /viewport\.width must be a positive integer/)
    end

    it "rejects malformed glob patterns" do
      write_config(repo_dir, <<~YAML)
        routes:
          - path: /
            name: homepage
        ui_patterns:
          - "app/views/[**/*"
      YAML

      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /ui_patterns\[0\] must be a valid glob pattern/)
    end
  end

  describe ".from_blob" do
    it "reads config from a GitHub blob" do
      blob = Struct.new(:content).new(Base64.strict_encode64(<<~YAML))
        routes:
          - path: /
            name: homepage
      YAML

      config = described_class.from_blob(blob, project: project)

      expect(config.routes.first).to have_attributes(path: "/", name: "homepage")
    end
  end
end
