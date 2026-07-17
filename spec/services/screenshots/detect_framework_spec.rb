# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::DetectFramework, :no_db do
  def fixture_path(name)
    Rails.root.join("spec/fixtures/screenshots/#{name}").to_s
  end

  def build_phx_gen_auth_repo(repo_path)
    FileUtils.mkdir_p(File.join(repo_path, "lib/my_app_web/controllers"))
    File.write(File.join(repo_path, "mix.exs"), "defmodule MyApp.MixProject do\nend\n")
    File.write(File.join(repo_path, "lib/my_app_web/router.ex"), <<~ELIXIR)
      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        scope "/", MyAppWeb do
          pipe_through :browser

          get "/", PageController, :index
          get "/users/log_in", UserSessionController, :new
        end
      end
    ELIXIR
    File.write(File.join(repo_path, "lib/my_app_web/controllers/user_session_controller.ex"), "defmodule MyAppWeb.UserSessionController do\nend\n")
  end

  def build_phoenix_pipeline_auth_repo(repo_path)
    FileUtils.mkdir_p(File.join(repo_path, "lib/my_app_web/controllers"))
    File.write(File.join(repo_path, "mix.exs"), <<~ELIXIR)
      defmodule MyApp.MixProject do
        defp deps do
          [{:phoenix, "~> 1.7.0"}]
        end
      end
    ELIXIR
    File.write(File.join(repo_path, "lib/my_app_web/router.ex"), <<~ELIXIR)
      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        pipeline :browser do
          plug :accepts, ["html"]
          plug :fetch_session
        end

        pipeline :require_authenticated_user do
          plug MyAppWeb.UserAuth, :ensure_authenticated
        end

        scope "/", MyAppWeb do
          pipe_through :browser

          get "/users/log_in", UserSessionController, :new
        end

        scope "/", MyAppWeb do
          pipe_through [:browser, :require_authenticated_user]

          live "/dashboard", DashboardLive, :index
        end
      end
    ELIXIR
  end

  def build_phoenix_pipeline_auth_repo_with_late_login(repo_path)
    FileUtils.mkdir_p(File.join(repo_path, "lib/my_app_web"))
    File.write(File.join(repo_path, "mix.exs"), <<~ELIXIR)
      defmodule MyApp.MixProject do
        defp deps do
          [{:phoenix, "~> 1.7.0"}]
        end
      end
    ELIXIR
    File.write(File.join(repo_path, "lib/my_app_web/router.ex"), <<~ELIXIR)
      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        pipeline :browser do
          plug :accepts, ["html"]
        end

        pipeline :require_authenticated_user do
          plug MyAppWeb.UserAuth, :ensure_authenticated
        end

        scope "/", MyAppWeb do
          pipe_through :browser

          get "/route1", PageController, :show
          get "/route2", PageController, :show
          get "/route3", PageController, :show
          get "/route4", PageController, :show
          get "/route5", PageController, :show
          get "/route6", PageController, :show
          get "/route7", PageController, :show
          get "/route8", PageController, :show
          get "/route9", PageController, :show
          get "/route10", PageController, :show
          get "/users/log_in", UserSessionController, :new
        end

        scope "/", MyAppWeb do
          pipe_through [:browser, :require_authenticated_user]

          live "/dashboard", DashboardLive, :index
        end
      end
    ELIXIR
  end

  describe ".call" do
    it "detects a Rails app and suggests a Cuprite config" do
      result = described_class.call(repo_path: fixture_path("rails_repo"))

      expect(result.framework).to eq(:rails)
      expect(result.confidence).to eq(1.0)
      expect(result.suggested_config["driver"]).to eq("cuprite")
      expect(result.detected_services).to contain_exactly("postgres", "redis")
      expect(result.suggested_config.dig("auth", "strategy")).to eq("form")
      expect(result.suggested_config.dig("auth", "fields")).to eq(
        "email" => 'input[name="user[email]"]',
        "password" => 'input[name="user[password]"]',
        "submit" => 'button[type="submit"], input[type="submit"]'
      )
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
      expect(result.suggested_config.dig("auth", "fields")).to eq(
        "email" => 'input[name="username"]',
        "password" => 'input[name="password"]',
        "submit" => 'button[type="submit"], input[type="submit"]'
      )
    end

    it "detects a Phoenix app and parses router.ex routes" do
      result = described_class.call(repo_path: fixture_path("phoenix_repo"))

      expect(result.framework).to eq(:phoenix)
      expect(result.confidence).to eq(1.0)
      expect(result.suggested_config["driver"]).to eq("playwright")
      expect(result.suggested_config["base_url"]).to eq("http://localhost:4000")
      expect(result.detected_routes.map { |route| route["path"] }).to include("/", "/dashboard", "/reports", "/admin", "/admin/users")
    end

    it "detects Phoenix services from config/dev.exs adapters and mix.exs deps" do
      result = described_class.call(repo_path: fixture_path("phoenix_repo"))

      expect(result.detected_services).to include("postgres")
    end

    it "does not infer Phoenix auth from LiveView and browser routes alone" do
      result = described_class.call(repo_path: fixture_path("phoenix_repo"))

      expect(result.suggested_config.dig("auth", "strategy")).to eq("none")
    end

    it "detects Phoenix auth from authenticated pipelines plus a login route" do
      repo_path = Dir.mktmpdir

      begin
        build_phoenix_pipeline_auth_repo(repo_path)

        result = described_class.call(repo_path: repo_path)

        expect(result.suggested_config.dig("auth", "strategy")).to eq("form")
        expect(result.suggested_config.dig("auth", "login_path")).to eq("/users/log_in")
      ensure
        FileUtils.remove_entry(repo_path)
      end
    end

    it "detects Phoenix auth when the login route appears after the first 10 parsed routes" do
      repo_path = Dir.mktmpdir

      begin
        build_phoenix_pipeline_auth_repo_with_late_login(repo_path)

        result = described_class.call(repo_path: repo_path)

        expect(result.detected_routes.size).to eq(10)
        expect(result.detected_routes.map { |route| route["path"] }).not_to include("/users/log_in")
        expect(result.suggested_config.dig("auth", "strategy")).to eq("form")
        expect(result.suggested_config.dig("auth", "login_path")).to eq("/users/log_in")
      ensure
        FileUtils.remove_entry(repo_path)
      end
    end

    it "falls back to a generic app when no known framework is detected" do
      result = described_class.call(repo_path: fixture_path("generic_repo"))

      expect(result.framework).to eq(:generic)
      expect(result.confidence).to eq(0.45)
      expect(result.suggested_config["driver"]).to eq("playwright")
      expect(result.detected_routes).to eq([])
      expect(result.suggested_config["routes"]).to eq([
        { "path" => "/", "name" => "home", "requires_auth" => false }
      ])
      expect(result.suggested_yaml).to include('- path: "/"')
    end

    it "uses lower confidence when only generic frontend assets are present" do
      result = described_class.call(repo_path: fixture_path("generic_repo"))

      expect(result.confidence).to be < 0.5
    end

    context "with file_list" do
      it "detects Rails from routes, Gemfile, and app structure" do
        result = described_class.call(
          file_list: [ "Gemfile", "config/routes.rb", "app/controllers/home_controller.rb" ]
        )

        expect(result.framework).to eq(:rails)
      end

      it "detects Next.js from src/pages" do
        result = described_class.call(
          file_list: [ "next.config.ts", "package.json", "src/pages/index.tsx" ]
        )

        expect(result.framework).to eq(:nextjs)
        expect(result.detected_routes.map { |route| route["path"] }).to include("/")
      end

      it "detects Phoenix from mix.exs and lib/*_web/router.ex" do
        result = described_class.call(
          file_list: [ "mix.exs", "lib/my_app_web/router.ex" ]
        )

        expect(result.framework).to eq(:phoenix)
      end

      it "does not classify a plain Elixir repo (mix.exs only) as Phoenix" do
        result = described_class.call(file_list: [ "mix.exs" ])

        expect(result.framework).to eq(:generic)
      end

      it "does not classify a plain Elixir repo as Phoenix in lightweight detection" do
        expect(described_class.detect_framework_only(file_list: [ "mix.exs" ])).to eq(:generic)
      end

      it "falls back to generic for an empty file list" do
        result = described_class.call(file_list: [])

        expect(result.framework).to eq(:generic)
      end
    end

    context "with repo_path" do
      let(:repo_path) { Dir.mktmpdir }

      after { FileUtils.remove_entry(repo_path) }

      it "detects Next.js src/app layout from the filesystem" do
        FileUtils.mkdir_p(File.join(repo_path, "src/app"))
        File.write(File.join(repo_path, "next.config.js"), "export default {}")
        File.write(File.join(repo_path, "package.json"), JSON.dump({ "dependencies" => { "next" => "15.0.0" } }))
        File.write(File.join(repo_path, "src/app/page.tsx"), "export default function Page() {}")

        result = described_class.call(repo_path: repo_path)

        expect(result.framework).to eq(:nextjs)
        expect(result.detected_routes.map { |route| route["path"] }).to include("/")
      end

      it "detects phx.gen.auth when the generated login route and files are present" do
        build_phx_gen_auth_repo(repo_path)

        result = described_class.call(repo_path: repo_path)

        expect(result.framework).to eq(:phoenix)
        expect(result.suggested_config.dig("auth", "strategy")).to eq("form")
        expect(result.suggested_config.dig("auth", "login_path")).to eq("/users/log_in")
        expect(result.suggested_config.dig("auth", "fields")).to eq(
          "email" => 'input[name="user[email]"]',
          "password" => 'input[name="user[password]"]',
          "submit" => 'button[type="submit"], input[type="submit"]'
        )
      end

      it "ignores heavyweight directories while scanning the filesystem" do
        FileUtils.mkdir_p(File.join(repo_path, ".git/objects"))
        FileUtils.mkdir_p(File.join(repo_path, "node_modules/react"))
        FileUtils.mkdir_p(File.join(repo_path, "app/views"))
        FileUtils.mkdir_p(File.join(repo_path, "config"))
        File.write(File.join(repo_path, "config/routes.rb"), "# routes")
        File.write(File.join(repo_path, "Gemfile"), "gem 'rails'\n")
        File.write(File.join(repo_path, ".git/objects/packfile"), "ignored")
        File.write(File.join(repo_path, "node_modules/react/index.js"), "ignored")

        repo = described_class::LocalRepository.new(repo_path)

        expect(repo.paths).to include("Gemfile", "config/routes.rb")
        expect(repo.paths).not_to include(
          ".git/objects/packfile",
          "node_modules/react/index.js"
        )
      end
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

    it "captures mounted engines and wildcard match routes without verbs" do
      output = <<~ROUTES
                         Prefix Verb   URI Pattern                 Controller#Action
                            avo        /admin                      Avo::Engine
                                       /admin(/*path)(.:format)    operator_console_access#show
      ROUTES

      service = described_class.new(repo_path: fixture_path("rails_repo"))
      routes = service.send(:parse_rails_routes_output, output)

      expect(routes).to include(
        a_hash_including("path" => "/admin", "name" => "avo"),
        a_hash_including("path" => "/admin", "name" => "admin")
      )
    end
  end

  describe "fallback Rails route parsing" do
    it "keeps namespace prefixes across nested non-namespace blocks" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          namespace :admin do
            resources :users do
              get "audit"
            end

            get "dashboard"
          end
        end
      RUBY

      repo = instance_double(
        described_class::LocalRepository,
        respond_to?: false,
        read: routes
      )

      service = described_class.new(repo_path: fixture_path("rails_repo"))
      allow(service).to receive(:repo).and_return(repo)

      parsed_routes = service.send(:discover_rails_routes)

      expect(parsed_routes.map { |route| route["path"] }).to include("/admin/users", "/admin/dashboard")
    end

    it "detects mounted engines and wildcard match routes behind auth blocks" do
      routes = <<~RUBY
        Rails.application.routes.draw do
          authenticate :user, ->(user) { user.operator? } do
            mount_avo at: "/admin"
          end

          match "/admin(/*path)", to: "operator_console_access#show", via: :all
        end
      RUBY

      repo = instance_double(
        described_class::LocalRepository,
        respond_to?: false,
        read: routes
      )

      service = described_class.new(repo_path: fixture_path("rails_repo"))
      allow(service).to receive(:repo).and_return(repo)

      parsed_routes = service.send(:discover_rails_routes)

      expect(parsed_routes.map { |route| route["path"] }).to include("/admin")
    end
  end

  describe "Django url parsing" do
    def django_repo_with_included_urls
      instance_double(
        described_class::LocalRepository,
        glob: [ "config/settings.py", "project/urls.py", "blog/urls.py" ]
      ).tap do |repo|
        allow(repo).to receive(:file?) do |path|
          [ "project/urls.py", "blog/urls.py" ].include?(path)
        end
        allow(repo).to receive(:read).with("config/settings.py").and_return('ROOT_URLCONF = "project.urls"')
        allow(repo).to receive(:read).with("project/urls.py").and_return(<<~PY)
          from django.urls import include, path

          urlpatterns = [
            path("blog/", include("blog.urls")),
          ]
        PY
        allow(repo).to receive(:read).with("blog/urls.py").and_return(<<~PY)
          from django.urls import path

          urlpatterns = [
            path("posts/", views.posts),
          ]
        PY
      end
    end

    it "carries include prefixes into child urlconfs" do
      repo = django_repo_with_included_urls
      service = described_class.new(repo_path: fixture_path("django_repo"))
      allow(service).to receive(:repo).and_return(repo)

      parsed_routes = service.send(:discover_django_routes)

      expect(parsed_routes.map { |route| route["path"] }).to include("/blog/posts/")
      expect(parsed_routes.map { |route| route["path"] }).not_to include("/posts/")
    end
  end

  describe "Phoenix router parsing" do
    def phoenix_repo_with_router(router_content)
      instance_double(
        described_class::LocalRepository,
        glob: [ "lib/my_app_web/router.ex" ]
      ).tap do |repo|
        allow(repo).to receive(:file?) do |path|
          [ "lib/my_app_web/router.ex" ].include?(path)
        end
        allow(repo).to receive(:read).with("lib/my_app_web/router.ex").and_return(router_content)
        allow(repo).to receive(:read).with("mix.exs").and_return("")
        allow(repo).to receive(:read).with("config/dev.exs").and_return("")
        allow(repo).to receive(:read).with("config/runtime.exs").and_return("")
      end
    end

    it "extracts get, post, live, and resources routes" do
      router = <<~EX
        defmodule MyAppWeb.Router do
          use MyAppWeb, :router

          scope "/", MyAppWeb do
            get "/", PageController, :index
            post "/contact", PageController, :create
            live "/dashboard", DashboardLive, :index
            resources "/reports", ReportController
          end
        end
      EX
      repo = phoenix_repo_with_router(router)
      service = described_class.new(repo_path: fixture_path("phoenix_repo"))
      allow(service).to receive(:repo).and_return(repo)

      parsed_routes = service.send(:discover_phoenix_routes)
      paths = parsed_routes.map { |r| r["path"] }

      expect(paths).to include("/", "/contact", "/dashboard", "/reports")
    end

    it "extracts match routes where the verb is the first argument" do
      router = <<~EX
        defmodule MyAppWeb.Router do
          use MyAppWeb, :router

          scope "/", MyAppWeb do
            get "/", PageController, :index
            match :*, "/health", HealthController, :show
            match :get, "/ping", HealthController, :ping
            match [:get, :post], "/batch", HealthController, :batch
            forward "/proxy", ApiProxy
          end
        end
      EX
      repo = phoenix_repo_with_router(router)
      service = described_class.new(repo_path: fixture_path("phoenix_repo"))
      allow(service).to receive(:repo).and_return(repo)

      paths = service.send(:discover_phoenix_routes).map { |r| r["path"] }

      expect(paths).to include("/health", "/ping", "/batch", "/proxy")
    end

    it "carries scope prefixes into nested routes" do
      router = <<~EX
        defmodule MyAppWeb.Router do
          use MyAppWeb, :router

          scope "/admin", MyAppWeb.Admin do
            get "/", AdminController, :index
            resources "/users", UserController
          end
        end
      EX
      repo = phoenix_repo_with_router(router)
      service = described_class.new(repo_path: fixture_path("phoenix_repo"))
      allow(service).to receive(:repo).and_return(repo)

      parsed_routes = service.send(:discover_phoenix_routes)
      paths = parsed_routes.map { |r| r["path"] }

      expect(paths).to include("/admin", "/admin/users")
    end

    it "derives resource route names from the full path without leading slashes" do
      router = <<~EX
        defmodule MyAppWeb.Router do
          use MyAppWeb, :router

          scope "/", MyAppWeb do
            resources "/reports", ReportController
          end

          scope "/admin", MyAppWeb.Admin do
            resources "/users", UserController
          end
        end
      EX
      repo = phoenix_repo_with_router(router)
      service = described_class.new(repo_path: fixture_path("phoenix_repo"))
      allow(service).to receive(:repo).and_return(repo)

      names = service.send(:discover_phoenix_routes).each_with_object({}) do |route, hash|
        hash[route["path"]] = route["name"]
      end

      expect(names["/reports"]).to eq("reports")
      expect(names["/admin/users"]).to eq("admin_users")
    end
  end

  describe "Phoenix service detection" do
    def service_with_mix(content)
      repo = instance_double(
        described_class::LocalRepository,
        file?: false,
        directory?: false,
        glob: [],
        paths: []
      )
      allow(repo).to receive(:read).with("Gemfile").and_return("")
      allow(repo).to receive(:read).with("package.json").and_return("")
      allow(repo).to receive(:read).with("mix.exs").and_return(content)
      allow(repo).to receive(:read).with("config/database.yml").and_return("")
      allow(repo).to receive(:read).with("config/dev.exs").and_return("")
      allow(repo).to receive(:read).with("config/runtime.exs").and_return("")
      service = described_class.new(repo_path: fixture_path("phoenix_repo"))
      allow(service).to receive(:repo).and_return(repo)
      service
    end

    it "provisions mysql from myxql without inferring postgres from phoenix_ecto" do
      service = service_with_mix(<<~EX)
        defp deps do
          [
            {:phoenix_ecto, "~> 4.4"},
            {:myxql, ">= 0.0.0"}
          ]
        end
      EX

      expect(service.send(:detect_services)).to contain_exactly("mysql")
    end

    it "provisions sqlite from ecto_sqlite3 without inferring postgres" do
      service = service_with_mix(<<~EX)
        defp deps do
          [
            {:ecto_sqlite3, "~> 0.10"}
          ]
        end
      EX

      expect(service.send(:detect_services)).to contain_exactly("sqlite")
    end

    it "does not infer redis from phoenix_pubsub" do
      service = service_with_mix(<<~EX)
        defp deps do
          [
            {:phoenix_pubsub, "~> 2.1"}
          ]
        end
      EX

      expect(service.send(:detect_services)).to eq([])
    end
  end

  describe "Elixir mix dependency parsing" do
    it "extracts dependency names from mix.exs defp deps" do
      content = <<~EX
        defp deps do
          [
            {:phoenix, "~> 1.7.0"},
            {:phoenix_ecto, "~> 4.4"},
            {:postgrex, ">= 0.0.0"}
          ]
        end
      EX

      repo = instance_double(described_class::LocalRepository)
      allow(repo).to receive(:read).with("mix.exs").and_return(content)
      service = described_class.new(repo_path: fixture_path("phoenix_repo"))
      allow(service).to receive(:repo).and_return(repo)

      deps = service.send(:elixir_mix_dependencies)

      expect(deps).to contain_exactly("phoenix", "phoenix_ecto", "postgrex")
    end

    it "returns an empty array when mix.exs has no deps block" do
      repo = instance_double(described_class::LocalRepository)
      allow(repo).to receive(:read).with("mix.exs").and_return("# no deps")
      service = described_class.new(repo_path: fixture_path("phoenix_repo"))
      allow(service).to receive(:repo).and_return(repo)

      expect(service.send(:elixir_mix_dependencies)).to eq([])
    end

    it "returns an empty array when mix.exs is missing" do
      repo = instance_double(described_class::LocalRepository)
      allow(repo).to receive(:read).with("mix.exs").and_return(nil)
      service = described_class.new(repo_path: fixture_path("phoenix_repo"))
      allow(service).to receive(:repo).and_return(repo)

      expect(service.send(:elixir_mix_dependencies)).to eq([])
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
      allow(repo).to receive(:read).with("mix.exs").and_return("")
      allow(repo).to receive(:read).with("config/database.yml").and_return("")
      allow(repo).to receive(:read).with("config/dev.exs").and_return("")
      allow(repo).to receive(:read).with("config/runtime.exs").and_return("")
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

  describe "GitHub repository reads" do
    it "uses the project's configured default branch for both tree and file reads" do
      client = instance_double(GithubClient)
      project = double(
        client:,
        full_name: "acme/widgets",
        default_branch: "develop"
      )

      tree_item = double(type: "blob", path: "README.md")
      tree = double(tree: [ tree_item ])

      allow(client).to receive(:tree).with("acme/widgets", "develop", recursive: true).and_return(tree)
      allow(client).to receive(:file_content).with("acme/widgets", path: "README.md", ref: "develop").and_return(+"# Widgets")

      repo = described_class::GithubRepository.new(project)

      expect(repo.paths).to eq([ "README.md" ])
      expect(repo.read("README.md")).to eq("# Widgets")
    end
  end
end
