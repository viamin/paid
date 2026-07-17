# frozen_string_literal: true

require "base64"
require "rails_helper"

RSpec.describe Screenshots::ConfigParser do
  def write_config(dir, content)
    write_config_at(dir, ".paid/screenshots.yml", content)
  end

  def write_config_at(dir, path, content)
    full_path = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end

  let(:repo_dir) { Dir.mktmpdir }
  let(:project) { build(:project) }

  after do
    FileUtils.rm_rf(repo_dir)
  end

  describe ".ui_detection_overrides" do
    it "returns explicit UI pattern overrides from the repo config" do
      write_config(repo_dir, <<~YAML)
        routes:
          - path: /
            name: homepage
        ui_patterns:
          - frontend/**/*
        ui_exclusions:
          - frontend/vendor/**/*
      YAML

      expect(described_class.ui_detection_overrides(repo_path: repo_dir)).to eq(
        patterns: [ "frontend/**/*" ],
        exclusions: [ "frontend/vendor/**/*" ]
      )
    end

    it "returns an explicit framework override from project screenshot settings" do
      project.screenshot_settings = { "framework" => "nextjs" }
      write_config(repo_dir, <<~YAML)
        routes:
          - path: /
            name: homepage
      YAML

      expect(described_class.ui_detection_overrides(project:, repo_path: repo_dir)).to eq(
        framework: :nextjs
      )
    end

    it "returns project screenshot setting overrides without a repo config file" do
      project.screenshot_settings = { "framework" => "nextjs" }

      expect(described_class.ui_detection_overrides(project:, repo_path: repo_dir)).to eq(
        framework: :nextjs
      )
    end

    it "reads UI overrides from the project-configured config path" do
      project.screenshot_settings = { "config_path" => ".paid/custom-screenshots.yml" }
      write_config_at(repo_dir, ".paid/custom-screenshots.yml", <<~YAML)
        routes:
          - path: /
            name: homepage
        ui_patterns:
          - frontend/**/*
      YAML

      expect(described_class.ui_detection_overrides(project:, repo_path: repo_dir)).to eq(
        patterns: [ "frontend/**/*" ]
      )
    end

    it "rejects UI override config paths that escape the repo" do
      project.screenshot_settings = { "config_path" => "../custom-screenshots.yml" }

      expect {
        described_class.ui_detection_overrides(project:, repo_path: repo_dir)
      }.to raise_error(Screenshots::ConfigError, "config_path escapes the repo directory")
    end

    it "rejects UI override config paths that point to a directory" do
      project.screenshot_settings = { "config_path" => "." }

      expect {
        described_class.ui_detection_overrides(project:, repo_path: repo_dir)
      }.to raise_error(Screenshots::ConfigError, ". must be a file")
    end

    it "does not return default Rails UI patterns when the repo config omits them" do
      write_config(repo_dir, <<~YAML)
        routes:
          - path: /
            name: homepage
      YAML

      expect(described_class.ui_detection_overrides(repo_path: repo_dir)).to eq({})
    end
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

    context "with a custom project config path" do
      subject(:config) { described_class.from_repo_path(repo_dir, project: project) }

      before do
        project.screenshot_settings = { "config_path" => ".paid/custom-screenshots.yml" }

        write_config_at(repo_dir, ".paid/custom-screenshots.yml", <<~YAML)
          routes:
            - path: /dashboard
              name: dashboard
        YAML
      end

      it "reads the configured file instead of the default path" do
        expect(config.routes).to contain_exactly(
          have_attributes(path: "/dashboard", name: "dashboard", requires_auth: false, seed_key: nil)
        )
      end

      it "rejects configured paths that escape the repo" do
        project.screenshot_settings = { "config_path" => "../custom-screenshots.yml" }

        expect { config }.to raise_error(
          Screenshots::ConfigError,
          "config_path escapes the repo directory"
        )
      end

      it "rejects configured paths that point to a directory" do
        project.screenshot_settings = { "config_path" => "." }

        expect { config }.to raise_error(
          Screenshots::ConfigError,
          ". must be a file"
        )
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
          setup_commands:
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
        expect(config.setup_commands).to eq([ "bin/rails db:prepare", "bin/rails db:seed" ])
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
          "setup_commands" => [ "bin/rails db:prepare" ]
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
        expect(config.setup_commands).to eq([ "yarn build" ])
      end
    end

    it "accepts runner-based seed entries" do
      write_config(repo_dir, <<~YAML)
        routes:
          - path: /
            name: homepage
        seed:
          - key: __all__
            runner: Screenshots::SeedData::Paid.call
      YAML

      config = described_class.from_repo_path(repo_dir, project: project)

      expect(config.seed.first).to have_attributes(key: "__all__", runner: "Screenshots::SeedData::Paid.call")
    end

    it "rejects raw ruby seed runners" do
      write_config(repo_dir, <<~YAML)
        routes:
          - path: /
            name: homepage
        seed:
          - key: __all__
            runner: |
              { "user" => { "id" => 1 } }
      YAML

      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /seed\[0\]\.runner must reference Screenshots::SeedData::<Runner>\.call/)
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

    it "accepts Phoenix as a known framework" do
      write_config(repo_dir, <<~YAML)
        framework: laravel
        routes:
          - path: /
            name: homepage
      YAML

      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /framework must be one of: rails, nextjs, django, phoenix, generic/)
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

    it "accepts a partial viewport with only width" do
      write_config(repo_dir, <<~YAML)
        viewport:
          width: 1440
        routes:
          - path: /
            name: homepage
      YAML

      config = described_class.from_repo_path(repo_dir, project: project)

      expect(config.viewport).to have_attributes(width: 1440, height: 900)
    end

    it "accepts a partial viewport with only height" do
      write_config(repo_dir, <<~YAML)
        viewport:
          height: 1080
        routes:
          - path: /
            name: homepage
      YAML

      config = described_class.from_repo_path(repo_dir, project: project)

      expect(config.viewport).to have_attributes(width: 1280, height: 1080)
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

    it "wraps Psych::DisallowedClass in ConfigError for YAML symbols" do
      write_config(repo_dir, <<~YAML)
        routes:
          - path: /
            name: homepage
        seed:
          - model: User
            factory: :admin
            key: user
      YAML

      expect {
        described_class.from_repo_path(repo_dir, project: project)
      }.to raise_error(Screenshots::ConfigError, /unsupported YAML types/)
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
