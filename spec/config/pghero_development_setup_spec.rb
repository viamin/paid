# frozen_string_literal: true

require "rails_helper"
require "erb"
require "yaml"

class PgheroDevelopmentSetup < Pathname
end

# @spec DEV-TOOLING-001
# @spec DEV-TOOLING-002
# @spec DEV-TOOLING-003
# @spec DEV-TOOLING-004
RSpec.describe PgheroDevelopmentSetup, :no_db, type: :request do
  subject(:gemfile_source) { Rails.root.join("Gemfile").read }

  let(:routes_source) { Rails.root.join("config/routes.rb").read }
  let(:pghero_config_path) { Rails.root.join("config/pghero.yml") }
  let(:dockerfile_source) { Rails.root.join("Dockerfile").read }

  describe "gem declaration" do
    it "keeps pghero in the development group so test and production never load it" do
      expect(group_containing_gem("pghero")).to eq("development")
    end

    it "does not declare pghero outside any group" do
      expect(declared_gems_outside_groups).not_to include("pghero")
    end
  end

  describe "route mounting" do
    let(:mount_line) { routes_source.lines.find { |line| line.include?("PgHero::Engine") } }

    it "mounts the dashboard at /pghero" do
      expect(mount_line).to be_present
      expect(mount_line).to include('at: "pghero"')
    end

    it "guards the mount with the development environment check" do
      expect(mount_line).to include("Rails.env.development?")
    end

    it "keeps the dashboard route out of the route table outside development" do
      mounted_paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }

      expect(mounted_paths.grep(%r{\A/pghero})).to be_empty
    end

    it "does not serve the dashboard outside development" do
      get "/pghero"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "dashboard connection" do
    around do |example|
      original = ENV.fetch("PGHERO_DATABASE_URL", :unset)
      example.run
    ensure
      if original == :unset
        ENV.delete("PGHERO_DATABASE_URL")
      else
        ENV["PGHERO_DATABASE_URL"] = original
      end
    end

    it "inspects the app development primary database by default" do
      ENV.delete("PGHERO_DATABASE_URL")

      expect(rendered_pghero_config.dig("databases", "primary")).to eq("spec" => "primary")
    end

    it "honors an explicit PGHERO_DATABASE_URL override" do
      ENV["PGHERO_DATABASE_URL"] = "postgres://paid_admin:paid_admin@postgres:5432/paid_development"

      expect(rendered_pghero_config.dig("databases", "primary")).to eq(
        "url" => "postgres://paid_admin:paid_admin@postgres:5432/paid_development"
      )
    end
  end

  describe "production image" do
    it "excludes the development group so the dashboard gem is never installed in production" do
      expect(dockerfile_source).to include('BUNDLE_WITHOUT="development"')
    end
  end

  describe "documentation" do
    let(:readme_source) { Rails.root.join("README.md").read }
    let(:contributing_source) { Rails.root.join("CONTRIBUTING.md").read }
    let(:env_example_source) { Rails.root.join(".env.example").read }

    it "documents the dashboard URL, the startup path, and the optional environment variable" do
      expect(readme_source).to include("http://localhost:3000/pghero")
      expect(readme_source).to include("PGHERO_DATABASE_URL")
      expect(readme_source).to include("bin/dev")
    end

    it "lists the dashboard among the common local endpoints" do
      expect(contributing_source).to include("http://localhost:3000/pghero")
    end

    it "records the optional environment variable in the example env file" do
      expect(env_example_source).to include("PGHERO_DATABASE_URL")
    end
  end

  private

  def rendered_pghero_config
    YAML.safe_load(ERB.new(pghero_config_path.read).result, aliases: true)
  end

  def group_containing_gem(gem_name)
    group = nil

    gemfile_source.each_line do |line|
      if (match = line.match(/^group\s+(.+?)\s+do\s*$/))
        group = match[1].delete(":")
      elsif line.match?(/^end\s*$/)
        group = nil
      elsif line.match?(/^\s*gem\s+["']#{Regexp.escape(gem_name)}["']/)
        return group || "default"
      end
    end

    nil
  end

  def declared_gems_outside_groups
    group = nil
    gems = []

    gemfile_source.each_line do |line|
      if (match = line.match(/^group\s+(.+?)\s+do\s*$/))
        group = match[1]
      elsif line.match?(/^end\s*$/)
        group = nil
      elsif (match = line.match(/^\s*gem\s+["']([^"']+)["']/)) && group.nil?
        gems << match[1]
      end
    end

    gems
  end
end
