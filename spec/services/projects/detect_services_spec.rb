# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Projects::DetectServices do
  let(:github_client) { instance_double(GithubClient) }

  # Use lightweight stubs for AR models to avoid DB connections during class loading
  let(:github_token_stub) { Struct.new(:client).new(github_client) }
  let(:project) { Struct.new(:owner, :repo, :github_token).new("test-owner", "test-repo", github_token_stub) }

  let(:service_container_class) do
    Class.new do
      def self.all
        raise "stub me"
      end
    end
  end

  before do
    stub_const("ServiceContainer", service_container_class)
    # Default: all files return NotFound
    allow(github_client).to receive(:contents).and_raise(GithubClient::NotFoundError)
    # Default: no service containers exist
    allow(service_container_class).to receive(:all).and_return([])
  end

  def stub_file(path, content)
    encoded = Base64.encode64(content)
    response = OpenStruct.new(content: encoded)
    allow(github_client).to receive(:contents)
      .with("test-owner/test-repo", path: path)
      .and_return(response)
  end

  def stub_containers(*names)
    containers_by_name = names.each_with_object({}) do |name, hash|
      hash[name] = Struct.new(:name).new(name)
    end
    container_list = containers_by_name.values
    allow(service_container_class).to receive(:all).and_return(container_list)
    allow(container_list).to receive(:index_by).and_return(containers_by_name)
    containers_by_name
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
        result = described_class.call(project: project)

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis")
      end

      it "deduplicates redis from both redis gem and sidekiq" do
        result = described_class.call(project: project)

        service_names = result.detected.map { |d| d[:service] }
        expect(service_names.count("redis")).to eq(1)
      end

      it "reports the source as Gemfile" do
        result = described_class.call(project: project)

        postgres_detection = result.detected.find { |d| d[:service] == "postgres" }
        expect(postgres_detection[:source]).to eq("Gemfile")
      end

      context "when matching containers exist" do
        it "returns matched containers" do
          containers = stub_containers("postgres", "redis")
          result = described_class.call(project: project)

          expect(result.matched).to contain_exactly(containers["postgres"], containers["redis"])
        end

        it "returns no unmatched" do
          stub_containers("postgres", "redis")
          result = described_class.call(project: project)

          expect(result.unmatched).to be_empty
        end
      end

      context "when no matching containers exist" do
        it "returns unmatched detections" do
          result = described_class.call(project: project)

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
        result = described_class.call(project: project)

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis", "elasticsearch")
      end

      it "reports the source as package.json" do
        result = described_class.call(project: project)

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
        result = described_class.call(project: project)

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis", "elasticsearch")
      end

      it "reports the source as docker-compose.yml" do
        result = described_class.call(project: project)

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

      it "falls back to compose.yml and reports correct source" do
        result = described_class.call(project: project)

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres")

        detection = result.detected.find { |d| d[:service] == "postgres" }
        expect(detection[:source]).to eq("compose.yml")
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
        result = described_class.call(project: project)

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres")
      end

      it "reports the source as config/database.yml" do
        result = described_class.call(project: project)

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
        result = described_class.call(project: project)

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
        result = described_class.call(project: project)

        postgres_detections = result.detected.select { |d| d[:service] == "postgres" }
        expect(postgres_detections.size).to eq(1)
      end
    end

    context "when no files are found" do
      it "returns empty results" do
        result = described_class.call(project: project)

        expect(result.detected).to be_empty
        expect(result.matched).to be_empty
        expect(result.unmatched).to be_empty
        expect(result.any_detected?).to be false
      end
    end

    context "when files contain invalid content" do
      it "handles invalid JSON gracefully" do
        stub_file("package.json", "not valid json {{{")

        result = described_class.call(project: project)
        expect(result.detected).to be_empty
      end

      it "handles invalid YAML gracefully" do
        stub_file("docker-compose.yml", "invalid: yaml: content: [}")

        result = described_class.call(project: project)
        expect(result.detected).to be_empty
      end

      it "handles YAML with disallowed classes in docker-compose.yml" do
        allow(YAML).to receive(:safe_load).and_raise(Psych::DisallowedClass.new("action", "Symbol"))
        stub_file("docker-compose.yml", "services: {}")

        result = described_class.call(project: project)
        expect(result.detected).to be_empty
      end

      it "handles YAML with disallowed classes in database.yml" do
        allow(YAML).to receive(:safe_load).and_raise(Psych::DisallowedClass.new("action", "Symbol"))
        stub_file("config/database.yml", "default:\n  adapter: postgresql")

        result = described_class.call(project: project)
        expect(result.detected).to be_empty
      end
    end

    context "when config/database.yml contains multi-line ERB" do
      before do
        stub_file("config/database.yml", <<~YAML)
          default: &default
            adapter: postgresql
            pool: <%
              if ENV["RAILS_MAX_THREADS"]
                ENV["RAILS_MAX_THREADS"]
              else
                5
              end
            %>

          production:
            <<: *default
        YAML
      end

      it "handles multi-line ERB templates gracefully" do
        result = described_class.call(project: project)

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres")
      end
    end

    context "when docker-compose.yml uses YAML anchors" do
      before do
        stub_file("docker-compose.yml", <<~YAML)
          x-common: &common
            restart: always

          services:
            db:
              <<: *common
              image: postgres:16
            cache:
              <<: *common
              image: redis:7
        YAML
      end

      it "detects services from compose files with anchors" do
        result = described_class.call(project: project)

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis")
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
        result = described_class.call(project: project)

        services = result.detected.map { |d| d[:service] }
        expect(services).to include("postgres", "redis")
      end
    end
  end
end
