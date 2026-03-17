# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Projects::DetectServices do
  let(:octokit_client) { instance_double(Octokit::Client) }
  let(:project_owner) { "test-owner" }
  let(:project_repo) { "test-repo" }
  let(:service) { described_class.new(project: project_stub) }
  let(:project_stub) do
    github_token_stub = OpenStruct.new(
      client: OpenStruct.new(client: octokit_client)
    )
    OpenStruct.new(owner: project_owner, repo: project_repo, github_token: github_token_stub)
  end

  before do
    # Default: all files return 404
    allow(octokit_client).to receive(:contents).and_raise(Octokit::NotFound.new)
  end

  def stub_file(path, content)
    encoded = Base64.encode64(content)
    response = OpenStruct.new(content: encoded)
    allow(octokit_client).to receive(:contents)
      .with("test-owner/test-repo", path: path)
      .and_return(response)
  end

  # Override the service's call to use a stubbed container lookup instead of hitting the DB.
  def call_with_containers(containers_by_name = {})
    result_detections = []
    result_detections.concat(service.send(:detect_from_gemfile))
    result_detections.concat(service.send(:detect_from_package_json))
    result_detections.concat(service.send(:detect_from_docker_compose))
    result_detections.concat(service.send(:detect_from_database_yml))

    unique_services = result_detections.uniq { |d| d[:service] }

    matched = []
    unmatched = []

    unique_services.each do |detection|
      container = containers_by_name[detection[:service]]
      if container
        matched << container
      else
        unmatched << detection
      end
    end

    described_class::Result.new(
      detected: unique_services,
      matched: matched.uniq,
      unmatched: unmatched
    )
  end

  describe ".call" do
    context "when Gemfile contains pg and redis gems" do
      before do
        stub_file("Gemfile", <<~GEMFILE)
          source "https://rubygems.org"
          gem "rails"
          gem "pg"
          gem "redis"
          gem "sidekiq"
        GEMFILE
      end

      it "detects postgres and redis services" do
        result = call_with_containers

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis")
      end

      it "deduplicates redis from both redis gem and sidekiq" do
        result = call_with_containers

        service_names = result.detected.map { |d| d[:service] }
        expect(service_names.count("redis")).to eq(1)
      end

      it "reports the source as Gemfile" do
        result = call_with_containers

        postgres_detection = result.detected.find { |d| d[:service] == "postgres" }
        expect(postgres_detection[:source]).to eq("Gemfile")
      end

      context "when matching containers exist" do
        let(:postgres_container) { OpenStruct.new(name: "postgres") }
        let(:redis_container) { OpenStruct.new(name: "redis") }

        it "returns matched containers" do
          result = call_with_containers("postgres" => postgres_container, "redis" => redis_container)

          expect(result.matched).to contain_exactly(postgres_container, redis_container)
        end

        it "returns no unmatched" do
          result = call_with_containers("postgres" => postgres_container, "redis" => redis_container)

          expect(result.unmatched).to be_empty
        end
      end

      context "when no matching containers exist" do
        it "returns unmatched detections" do
          result = call_with_containers

          expect(result.unmatched).to be_present
          unmatched_services = result.unmatched.map { |d| d[:service] }
          expect(unmatched_services).to include("postgres", "redis")
        end
      end
    end

    context "when package.json contains database dependencies" do
      before do
        stub_file("package.json", <<~JSON)
          {
            "name": "my-app",
            "dependencies": {
              "express": "^4.18.0",
              "pg": "^8.11.0",
              "ioredis": "^5.3.0"
            },
            "devDependencies": {
              "@elastic/elasticsearch": "^8.0.0"
            }
          }
        JSON
      end

      it "detects postgres, redis, and elasticsearch" do
        result = call_with_containers

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis", "elasticsearch")
      end

      it "reports the source as package.json" do
        result = call_with_containers

        result.detected.each do |detection|
          expect(detection[:source]).to eq("package.json")
        end
      end
    end

    context "when docker-compose.yml declares services" do
      before do
        stub_file("docker-compose.yml", <<~YAML)
          version: "3.8"
          services:
            db:
              image: postgres:16
              ports:
                - "5432:5432"
            cache:
              image: redis:7-alpine
              ports:
                - "6379:6379"
            search:
              image: elasticsearch:8.11.0
        YAML
      end

      it "detects services from compose images" do
        result = call_with_containers

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis", "elasticsearch")
      end

      it "reports the source as docker-compose.yml" do
        result = call_with_containers

        result.detected.each do |detection|
          expect(detection[:source]).to eq("docker-compose.yml")
        end
      end
    end

    context "when compose.yml is used instead of docker-compose.yml" do
      before do
        stub_file("compose.yml", <<~YAML)
          services:
            postgres:
              image: postgres:16
        YAML
      end

      it "falls back to compose.yml" do
        result = call_with_containers

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres")
      end
    end

    context "when config/database.yml specifies an adapter" do
      before do
        stub_file("config/database.yml", <<~YAML)
          default: &default
            adapter: postgresql
            encoding: unicode
            pool: 5

          development:
            <<: *default
            database: myapp_development

          test:
            <<: *default
            database: myapp_test
        YAML
      end

      it "detects postgres from the adapter" do
        result = call_with_containers

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres")
      end

      it "reports the source as config/database.yml" do
        result = call_with_containers

        db_detection = result.detected.find { |d| d[:source] == "config/database.yml" }
        expect(db_detection).to be_present
        expect(db_detection[:dependency]).to eq("postgresql")
      end
    end

    context "when config/database.yml contains ERB" do
      before do
        stub_file("config/database.yml", <<~YAML)
          default: &default
            adapter: postgresql
            encoding: unicode
            pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
            url: <%= ENV["DATABASE_URL"] %>

          production:
            <<: *default
        YAML
      end

      it "handles ERB templates gracefully" do
        result = call_with_containers

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres")
      end
    end

    context "when multiple sources detect the same service" do
      before do
        stub_file("Gemfile", <<~GEMFILE)
          gem "pg"
        GEMFILE
        stub_file("config/database.yml", <<~YAML)
          default:
            adapter: postgresql
        YAML
      end

      it "deduplicates across sources" do
        result = call_with_containers

        postgres_detections = result.detected.select { |d| d[:service] == "postgres" }
        expect(postgres_detections.size).to eq(1)
      end
    end

    context "when no files are found" do
      it "returns empty results" do
        result = call_with_containers

        expect(result.detected).to be_empty
        expect(result.matched).to be_empty
        expect(result.unmatched).to be_empty
        expect(result.any_detected?).to be false
      end
    end

    context "when files contain invalid content" do
      it "handles invalid JSON gracefully" do
        stub_file("package.json", "not valid json {{{")

        result = call_with_containers
        expect(result.detected).to be_empty
      end

      it "handles invalid YAML gracefully" do
        stub_file("docker-compose.yml", "invalid: yaml: content: [}")

        result = call_with_containers
        expect(result.detected).to be_empty
      end
    end

    context "when docker-compose.yml uses service names without explicit images" do
      before do
        stub_file("docker-compose.yml", <<~YAML)
          services:
            postgres:
              environment:
                POSTGRES_PASSWORD: secret
            redis:
              command: redis-server
        YAML
      end

      it "detects services from service names" do
        result = call_with_containers

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis")
      end
    end
  end
end
