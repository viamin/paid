# frozen_string_literal: true

require_relative "configuration"

require "find"
require "json"
require "open3"
require "psych"
require "set"
require "yaml"

module Screenshots
  class DetectFramework
    Result = ::Data.define(
      :framework,
      :confidence,
      :suggested_config,
      :detected_services,
      :detected_routes
    ) do
      def to_h
        {
          framework: framework,
          confidence: confidence,
          suggested_config: suggested_config,
          detected_services: detected_services,
          detected_routes: detected_routes
        }
      end

      def suggested_yaml
        Psych.dump(DetectFramework.deep_stringify(suggested_config))
      end
    end

    ROUTE_EXTENSIONS = %w[.js .jsx .ts .tsx .rb .py .ex].freeze
    NEXT_PAGE_EXTENSIONS = %w[.js .jsx .ts .tsx].freeze
    JS_DEPENDENCY_KEYS = %w[dependencies devDependencies].freeze
    SKIP_DIRECTORIES = %w[.git node_modules vendor tmp log].freeze
    DATABASE_ADAPTER_MAP = {
      "postgresql" => "postgres",
      "postgis" => "postgres",
      "mysql2" => "mysql",
      "trilogy" => "mysql",
      "sqlite3" => "sqlite",
      "redis" => "redis"
    }.freeze
    SERVICE_DEPENDENCY_MAP = {
      "pg" => "postgres",
      "postgres" => "postgres",
      "postgresql" => "postgres",
      "postgrex" => "postgres",
      "redis" => "redis",
      "redis-rb" => "redis",
      "redix" => "redis",
      "ioredis" => "redis",
      "sidekiq" => "redis",
      "mysql2" => "mysql",
      "mysql" => "mysql"
    }.freeze

    attr_reader :project, :repo_path, :file_list

    def self.call(...)
      new(...).call
    end

    # Lightweight detection that returns only the framework symbol.
    # Skips expensive route discovery, service scanning, and auth detection.
    def self.detect_framework_only(...)
      new(...).detect_framework_only
    end

    def initialize(project: nil, repo_path: nil, file_list: nil)
      @project = project
      @repo_path = repo_path
      @file_list = file_list
    end

    def call
      detection = detect_rails || detect_phoenix || detect_nextjs || detect_django || detect_generic
      detected_routes = detection.fetch(:routes)
      suggested_routes = present_value?(detected_routes) ? detected_routes : default_routes_for
      services = detect_services

      Result.new(
        framework: detection.fetch(:framework),
        confidence: detection.fetch(:confidence),
        suggested_config: build_suggested_config(
          framework: detection.fetch(:framework),
          driver: detection.fetch(:driver),
          routes: suggested_routes,
          services: services,
          auth: detection[:auth]
        ),
        detected_services: services,
        detected_routes: detected_routes
      )
    end

    # Returns only the framework symbol, skipping route discovery,
    # service scanning, and auth detection.
    def detect_framework_only
      detect_framework_identity(:rails) ||
        detect_framework_identity(:phoenix) ||
        detect_framework_identity(:nextjs) ||
        detect_framework_identity(:django) ||
        :generic
    end

    private

    def self.deep_stringify(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), result|
          result[key.to_s] = deep_stringify(nested_value)
        end
      when Array
        value.map { |item| deep_stringify(item) }
      else
        value
      end
    end

    # Runs only the confidence scoring for a given framework and returns the
    # symbol if the score meets the threshold, without discovering routes,
    # services, or auth configuration.
    def detect_framework_identity(framework)
      score = case framework
      when :rails then score_rails
      when :phoenix then score_phoenix
      when :nextjs then score_nextjs
      when :django then score_django
      end
      framework if score && score >= 0.5
    end

    def score_rails
      score = 0.0
      score += 0.55 if repo.file?("config/routes.rb")
      score += 0.3 if gemfile_dependency?("rails")
      score += 0.15 if repo.directory?("app/controllers")
      score
    end

    def score_nextjs
      score = 0.0
      score += 0.55 if %w[next.config.js next.config.mjs next.config.ts].any? { |path| repo.file?(path) }
      score += 0.3 if package_dependency?("next")
      score += 0.15 if %w[app pages src/app src/pages].any? { |path| repo.directory?(path) }
      score
    end

    def score_phoenix
      score = 0.0
      score += 0.55 if repo.file?("mix.exs")
      score += 0.3 if mix_dependency?("phoenix")
      score += 0.2 if mix_dependency?("phoenix_live_view")
      score += 0.15 if phoenix_router_paths.any?
      [ score, 1.0 ].min
    end

    def score_django
      score = 0.0
      score += 0.55 if repo.file?("manage.py")
      score += 0.25 if repo.glob("**/settings.py").any?
      score += 0.2 if repo.glob("**/urls.py").any?
      score
    end

    def repo
      @repo ||= begin
        return LocalRepository.new(repo_path) if present_value?(repo_path)
        return FileListRepository.new(file_list) unless file_list.nil?
        return GithubRepository.new(project) if present_value?(project)

        raise ArgumentError, "project, repo_path, or file_list is required"
      end
    end

    def detect_rails
      score = score_rails
      return unless score >= 0.5

      {
        framework: :rails,
        confidence: score.round(2),
        driver: "cuprite",
        auth: detect_rails_auth,
        routes: discover_rails_routes
      }
    end

    def detect_nextjs
      score = score_nextjs
      return unless score >= 0.5

      {
        framework: :nextjs,
        confidence: score.round(2),
        driver: "playwright",
        auth: detect_nextjs_auth,
        routes: discover_nextjs_routes
      }
    end

    def detect_phoenix
      score = score_phoenix
      return unless score >= 0.5

      {
        framework: :phoenix,
        confidence: score.round(2),
        driver: "playwright",
        auth: detect_phoenix_auth,
        routes: discover_phoenix_routes
      }
    end

    def detect_django
      score = score_django
      return unless score >= 0.5

      {
        framework: :django,
        confidence: score.round(2),
        driver: "playwright",
        auth: detect_django_auth,
        routes: discover_django_routes
      }
    end

    def detect_generic
      files = repo.paths
      html = files.any? { |path| path.end_with?(".html", ".erb", ".haml", ".slim") }
      css = files.any? { |path| path.end_with?(".css", ".scss", ".sass") }
      js = files.any? { |path| path.end_with?(".js", ".jsx", ".ts", ".tsx") }

      confidence = if html && (css || js)
        0.45
      elsif html || css || js
        0.3
      else
        0.2
      end

      {
        framework: :generic,
        confidence: confidence,
        driver: "playwright",
        auth: { "strategy" => "none" },
        routes: []
      }
    end

    def build_suggested_config(framework:, driver:, routes:, services:, auth:)
      config = {
        "enabled" => true,
        "driver" => driver,
        "base_url" => base_url_for(framework),
        "routes" => self.class.deep_stringify(routes)
      }
      config["services"] = services if services.any?
      config["auth"] = auth if present_value?(auth)
      config
    end

    def base_url_for(framework)
      framework == :django ? "http://localhost:8000" : Screenshots::Configuration::DEFAULT_BASE_URL
    end

    def default_routes_for
      [ route_hash("/", "home") ]
    end

    def detect_services
      services = Set.new

      extract_database_adapters.each do |adapter|
        mapped = DATABASE_ADAPTER_MAP[adapter]
        services << mapped if present_value?(mapped)
      end

      dependency_names.each do |dependency|
        mapped = SERVICE_DEPENDENCY_MAP[dependency]
        services << mapped if present_value?(mapped)
      end

      detect_elixir_services.each do |service|
        services << service
      end

      services.to_a.sort
    end

    def dependency_names
      @dependency_names ||= begin
        names = Set.new
        gemfile_dependencies.each { |name| names << name }
        package_dependencies.each { |name| names << name }
        names
      end
    end

    def gemfile_dependencies
      @gemfile_dependencies ||= begin
        content = repo.read("Gemfile")
        if blank_value?(content)
          []
        else
          content.scan(/^\s*gem\s+["']([^"']+)["']/).flatten
        end
      end
    end

    def gemfile_dependency?(name)
      gemfile_dependencies.include?(name)
    end

    def mix_dependencies
      @mix_dependencies ||= begin
        content = repo.read("mix.exs")
        if blank_value?(content)
          []
        else
          content.scan(/\{\s*:([a-zA-Z_][\w]*)\s*,/).flatten
        end
      end
    end

    def mix_dependency?(name)
      mix_dependencies.include?(name.to_s)
    end

    def package_dependencies
      @package_dependencies ||= begin
        content = repo.read("package.json")
        if blank_value?(content)
          []
        else
          data = JSON.parse(content)
          JS_DEPENDENCY_KEYS.flat_map do |key|
            deps = data[key]
            deps.is_a?(Hash) ? deps.keys : []
          end
        end
      rescue JSON::ParserError
        []
      end
    end

    def package_dependency?(name)
      package_dependencies.include?(name)
    end

    def extract_database_adapters
      content = repo.read("config/database.yml")
      return elixir_database_adapters if blank_value?(content)

      sanitized = content.gsub(/<%.*?%>/m, '""')
      data = YAML.safe_load(sanitized, aliases: true)
      adapters = []
      collect_adapters(data, adapters)
      adapters
    rescue Psych::Exception
      elixir_database_adapters
    end

    def collect_adapters(value, adapters)
      return unless value.is_a?(Hash)

      value.each_value do |child|
        next unless child.is_a?(Hash)

        if present_value?(child["adapter"])
          adapters << child["adapter"]
        else
          collect_adapters(child, adapters)
        end
      end
    end

    def detect_rails_auth
      return devise_auth_config if gemfile_dependency?("devise")

      routes = rails_routes_content
      return devise_auth_config if routes.include?("devise_for")

      { "strategy" => "none" }
    end

    def detect_phoenix_auth
      return { "strategy" => "none" } unless phoenix_auth_configured?

      login_path = discover_phoenix_routes
        .map { |route| route["path"] }
        .find { |path| path.match?(%r{/(?:users/)?(?:log_in|sign_in|login)\b}) } || "/users/log_in"

      {
        "strategy" => "form",
        "login_path" => login_path,
        "fields" => {
          "email" => "user[email]",
          "password" => "user[password]",
          "submit" => "Log in"
        }
      }
    end

    def devise_auth_config
      {
        "strategy" => "form",
        "login_path" => "/users/sign_in",
        "fields" => {
          "email" => "user[email]",
          "password" => "user[password]",
          "submit" => "Log in"
        }
      }
    end

    def detect_nextjs_auth
      auth_paths = repo.paths.select do |path|
        path.match?(%r{(?:app|pages|src/app|src/pages)/api/auth/.+nextauth}) ||
          path.include?("next-auth") ||
          path.include?("nextauth")
      end

      middleware = repo.read("middleware.ts").to_s + repo.read("middleware.js").to_s
      nextauth_detected = package_dependency?("next-auth") || package_dependency?("@auth/core") || auth_paths.any? ||
        middleware.match?(/nextauth|withAuth|auth\(/i)

      return { "strategy" => "none" } unless nextauth_detected

      {
        "strategy" => "custom",
        "login_path" => "/api/auth/signin"
      }
    end

    def detect_django_auth
      auth_file = repo.glob("**/urls.py").find do |path|
        repo.read(path).to_s.match?(/django\.contrib\.auth|accounts\/login/)
      end
      return { "strategy" => "none" } unless auth_file

      {
        "strategy" => "form",
        "login_path" => "/accounts/login/",
        "fields" => {
          "email" => "username",
          "password" => "password",
          "submit" => "Log in"
        }
      }
    end

    def discover_rails_routes
      routes_from_command = discover_rails_routes_from_command
      return routes_from_command if routes_from_command.any?

      content = rails_routes_content
      return [] if blank_value?(content)

      block_stack = []
      routes = []

      content.each_line.flat_map { |line| line.split(";") }.each do |statement|
        stripped = statement.strip
        next if stripped.start_with?("#")

        if (match = stripped.match(/^namespace\s+:([a-zA-Z_][\w]*)\s+do/))
          block_stack << match[1]
          next
        end

        if stripped == "end"
          block_stack.pop if block_stack.any?
          next
        end

        route = parse_rails_route_line(stripped, current_rails_prefixes(block_stack))
        routes << route if route

        block_stack << nil if opens_rails_block?(stripped)
      end

      unique_routes(routes)
    end

    def rails_routes_content
      @rails_routes_content ||= repo.read("config/routes.rb").to_s
    end

    def discover_rails_routes_from_command
      return [] unless repo.respond_to?(:root_path)

      root = repo.root_path
      return [] unless File.exist?(File.join(root, "bin/rails"))

      stdout, status = Open3.capture2e("bin/rails", "routes", chdir: root)
      return [] unless status.success?

      parse_rails_routes_output(stdout)
    rescue StandardError
      []
    end

    def parse_rails_routes_output(output)
      output.each_line.filter_map do |line|
        tokens = line.strip.split(/\s+/)
        next if tokens.empty?

        verb_index = tokens.index { |token| token.match?(/\A(?:GET|POST|PATCH|PUT|DELETE)\z/) }
        if verb_index && tokens[verb_index + 1]
          path = normalized_rails_route_segment(tokens[verb_index + 1])
          name = verb_index.positive? ? tokens[verb_index - 1] : path
          next route_hash(path, name, requires_auth: false)
        end

        # Mounted engines and wildcard match routes can appear without a verb in
        # `bin/rails routes` output, e.g. `avo /admin Avo::Engine` or
        # `/admin(/*path)(.:format) operator_console_access#show`.
        path_index = tokens.index { |token| token.start_with?("/") }
        next unless path_index

        path = normalized_rails_route_segment(tokens[path_index])
        name = path_index.positive? ? tokens[path_index - 1] : route_name_from_path(path)
        route_hash(path, name, requires_auth: false)
      end.then do |routes|
        unique_routes(routes) { |route| [ route["path"], route["name"] ] }
      end
    end

    def parse_rails_route_line(line, prefixes)
      return route_hash("/", "root") if line.match?(/^root\s+/)

      if (match = line.match(/^(?:get|post|patch|put|delete|match)\s+["']([^"']+)["']/))
        path = normalize_route_path(prefixes, normalized_rails_route_segment(match[1]))
        return route_hash(path, route_name_from_path(path))
      end

      if (match = line.match(/^resources\s+:([a-zA-Z_][\w]*)/))
        path = normalize_route_path(prefixes, match[1])
        return route_hash(path, match[1])
      end

      if (match = line.match(/^resource\s+:([a-zA-Z_][\w]*)/))
        path = normalize_route_path(prefixes, match[1])
        return route_hash(path, match[1])
      end

      if (match = line.match(/^mount(?:_[a-zA-Z_][\w]*)?\s+.+?\s+at:\s+["']([^"']+)["']/))
        path = normalize_route_path(prefixes, normalized_rails_route_segment(match[1]))
        return route_hash(path, route_name_from_path(path))
      end

      nil
    end

    def current_rails_prefixes(block_stack)
      block_stack.compact
    end

    def opens_rails_block?(line)
      line.end_with?(" do") || line.match?(/\sdo\s+\|[^|]*\|\s*\z/)
    end

    def discover_nextjs_routes
      routes = []

      repo.glob("app/**/page{#{NEXT_PAGE_EXTENSIONS.join(',')}}").each do |path|
        route = next_app_route_for(path, root: "app/")
        routes << route if route
      end

      repo.glob("src/app/**/page{#{NEXT_PAGE_EXTENSIONS.join(',')}}").each do |path|
        route = next_app_route_for(path, root: "src/app/")
        routes << route if route
      end

      repo.glob("pages/**/*{#{NEXT_PAGE_EXTENSIONS.join(',')}}").each do |path|
        route = next_pages_route_for(path, root: "pages/")
        routes << route if route
      end

      repo.glob("src/pages/**/*{#{NEXT_PAGE_EXTENSIONS.join(',')}}").each do |path|
        route = next_pages_route_for(path, root: "src/pages/")
        routes << route if route
      end

      unique_routes(routes)
    end

    def discover_phoenix_routes
      routes = phoenix_router_paths.flat_map do |path|
        parse_phoenix_router(repo.read(path).to_s)
      end

      unique_routes(routes)
    end

    def phoenix_router_paths
      @phoenix_router_paths ||= repo.glob("lib/*_web/router.ex")
    end

    def phoenix_router_content
      @phoenix_router_content ||= phoenix_router_paths.filter_map { |path| repo.read(path).to_s.presence }.join("\n")
    end

    def parse_phoenix_router(content)
      routes = []
      stack = []

      content.each_line.flat_map { |line| line.split(";") }.each do |statement|
        stripped = statement.strip
        next if stripped.blank? || stripped.start_with?("#")

        if stripped == "end"
          stack.pop if stack.any?
          next
        end

        current_prefix = current_phoenix_prefix(stack)
        requires_auth = phoenix_auth_required?(stack)

        if (route = parse_phoenix_route_line(stripped, current_prefix, requires_auth))
          routes << route
          next
        end

        if (match = stripped.match(/^scope\s+["']([^"']*)["'][^#]*\bdo\b/))
          stack << { prefix: match[1], requires_auth: false }
          next
        end

        if (pipelines = parse_phoenix_pipe_through(stripped))
          next if stack.empty?

          stack.last[:requires_auth] ||= pipelines.any? { |pipeline| auth_pipeline_name?(pipeline) }
          next
        end

        stack << { prefix: nil, requires_auth: false } if stripped.match?(/\bdo\b\s*$/)
      end

      unique_routes(routes)
    end

    def parse_phoenix_route_line(line, prefix, requires_auth)
      if (match = line.match(/^(?:live|get|post|put|patch|delete)\s+["']([^"']+)["']/))
        path = normalize_route_path([ prefix ].compact, match[1])
        return route_hash(path, route_name_from_path(path), requires_auth: requires_auth)
      end

      if (match = line.match(/^resources\s+["']([^"']+)["']\s*,\s*([^,\n]+)/))
        path = normalize_route_path([ prefix ].compact, match[1])
        return route_hash(path, "#{match[2].strip}#index", requires_auth: requires_auth)
      end

      if (match = line.match(/^resource\s+["']([^"']+)["']/))
        path = normalize_route_path([ prefix ].compact, match[1])
        return route_hash(path, route_name_from_path(path), requires_auth: requires_auth)
      end

      nil
    end

    def parse_phoenix_pipe_through(line)
      if (match = line.match(/^pipe_through\s+\[([^\]]+)\]/))
        return match[1].scan(/:([a-zA-Z_][\w]*)/).flatten
      end

      if (match = line.match(/^pipe_through\s+:([a-zA-Z_][\w]*)/))
        return [ match[1] ]
      end

      nil
    end

    def current_phoenix_prefix(stack)
      segments = stack.filter_map { |entry| entry[:prefix] }
      return "/" if segments.empty?

      normalize_route_path([], segments.join("/"))
    end

    def phoenix_auth_required?(stack)
      stack.any? { |entry| entry[:requires_auth] }
    end

    def auth_pipeline_name?(pipeline)
      pipeline.match?(/auth|login|session/i)
    end

    def phoenix_auth_configured?
      content = phoenix_router_content
      return false if blank_value?(content)

      content.match?(/pipe_through\s+(?:\[[^\]]*:require_authenticated_user|\s*:require_authenticated_user)/) ||
        content.match?(/\b(?:fetch_current_user|require_authenticated_user|redirect_if_user_is_authenticated)\b/) ||
        content.match?(/\b(?:Pow|Ueberauth|Guardian)\b/)
    end

    def next_app_route_for(path, root:)
      relative = path.delete_prefix(root).sub(%r{(?:^|/)page\.[^.]+$}, "")
      return if relative.start_with?("api/")

      segments = relative.split("/").reject { |segment| blank_value?(segment) || segment.start_with?("(") }
      route_path = "/" + segments.map { |segment| segment.gsub(/\[(.+?)\]/, ':\1') }.join("/")
      route_path = "/" if route_path == "/"

      route_hash(route_path, route_name_from_path(route_path))
    end

    def next_pages_route_for(path, root:)
      relative = path.delete_prefix(root)
      return if relative.start_with?("api/")
      return if relative.match?(%r{\A_(app|document|error)\.})

      route_path = relative.sub(/\.[^.]+\z/, "")
      route_path = route_path.delete_suffix("/index")
      route_path = "/" if blank_value?(route_path) || route_path == "index"
      route_path = "/#{route_path}" unless route_path.start_with?("/")
      route_path = route_path.gsub(/\[(.+?)\]/, ':\1')

      route_hash(route_path, route_name_from_path(route_path))
    end

    def discover_django_routes
      routes = django_root_url_files.flat_map do |path|
        parse_django_urlconf(path, prefix: "", visited: Set.new)
      end

      unique_routes(routes)
    end

    def django_root_url_files
      roots = django_root_url_files_from_settings
      return roots if roots.any?

      url_files = repo.glob("**/urls.py")
      included = url_files.flat_map do |path|
        parse_django_include_targets(repo.read(path).to_s)
      end.to_set
      root_files = url_files.reject { |path| included.include?(path) }
      root_files.presence || url_files
    end

    def django_root_url_files_from_settings
      repo.glob("**/settings.py").filter_map do |path|
        repo.read(path).to_s[/ROOT_URLCONF\s*=\s*["']([^"']+)["']/, 1]
      end.filter_map do |module_name|
        django_module_path(module_name)
      end.uniq
    end

    def parse_django_urlconf(path, prefix:, visited:)
      visit_key = [ path, prefix ]
      return [] if visited.include?(visit_key)

      visited << visit_key
      parse_django_urls(repo.read(path).to_s, prefix:, visited:)
    end

    def parse_django_urls(content, prefix:, visited:)
      content.each_line.filter_map do |line|
        if (include_match = line.match(/(?:path|re_path)\(\s*["']([^"']*)["']\s*,\s*include\((.+?)\)\s*[,\)]/))
          include_prefix = join_django_route_segments(prefix, include_match[1])
          include_module = django_include_module_name(include_match[2])
          include_path = present_value?(include_module) ? django_module_path(include_module) : nil

          next parse_django_urlconf(include_path, prefix: include_prefix, visited:) if present_value?(include_path)
          next route_hash(include_prefix, route_name_from_path(include_prefix))
        end

        next unless (match = line.match(/(?:path|re_path)\(\s*["']([^"']*)["']/))

        route_path = join_django_route_segments(prefix, match[1])
        route_hash(route_path, route_name_from_path(route_path))
      end.flatten
    end

    def parse_django_include_targets(content)
      content.each_line.filter_map do |line|
        include_match = line.match(/include\((.+?)\)/)
        next unless include_match

        include_module = django_include_module_name(include_match[1])
        next unless present_value?(include_module)

        django_module_path(include_module)
      end
    end

    def django_include_module_name(arguments)
      arguments[/["']([^"']+)["']/, 1]
    end

    def django_module_path(module_name)
      path = "#{module_name.tr('.', '/')}.py"
      repo.file?(path) ? path : nil
    end

    def join_django_route_segments(prefix, path)
      joined = [ prefix, path ].compact.reject { |segment| blank_value?(segment) }.join("/")
      normalized = joined.gsub(%r{/+}, "/").delete_prefix("/")
      present_value?(normalized) ? "/#{normalized}" : "/"
    end

    def elixir_database_adapters
      return [] unless phoenix_repo?

      content = repo.read("config/dev.exs").to_s
      adapters = []
      adapters << "postgresql" if content.match?(/Ecto\.Adapters\.Postgres|postgrex/i)
      adapters << "mysql2" if content.match?(/Ecto\.Adapters\.MyXQL|mysql/i)
      adapters << "sqlite3" if content.match?(/Ecto\.Adapters\.SQLite3|sqlite/i)
      adapters
    end

    def detect_elixir_services
      return [] unless phoenix_repo?

      content = repo.read("config/dev.exs").to_s
      return [] if blank_value?(content)

      services = []
      services << "postgres" if content.match?(/Ecto\.Adapters\.Postgres|postgrex/i)
      services << "redis" if content.match?(/\bRedix\b|redis:\/\//i)
      services
    end

    def phoenix_repo?
      repo.file?("mix.exs") || phoenix_router_paths.any?
    end

    def normalize_route_path(prefixes, path)
      full_path = ([ "", *prefixes, path ]).join("/")
      "/" + full_path.gsub(%r{/+}, "/").delete_prefix("/")
    end

    def normalized_rails_route_segment(path)
      path.to_s.sub(/\(\.:format\)\z/, "").sub(/\(\/\*[^)]+\)\z/, "")
    end

    def unique_routes(routes, &identity)
      identity ||= ->(route) { route["path"] }
      routes.compact.uniq(&identity).first(10)
    end

    def route_hash(path, name, requires_auth: false)
      {
        "path" => path,
        "name" => name,
        "requires_auth" => requires_auth
      }
    end

    def route_name_from_path(path)
      return "home" if path == "/"

      name = path.delete_prefix("/").tr("/", "_").gsub(":", "")
      present_value?(name) ? name : "home"
    end

    def blank_value?(value)
      case value
      when nil
        true
      when String
        value.strip.empty?
      when Array, Hash
        value.empty?
      else
        false
      end
    end

    def present_value?(value)
      !blank_value?(value)
    end

    class LocalRepository
      attr_reader :root_path

      def initialize(root_path)
        @root_path = root_path
      end

      def file?(path)
        File.file?(absolute(path))
      end

      def directory?(path)
        Dir.exist?(absolute(path))
      end

      def read(path)
        return unless file?(path)

        File.read(absolute(path), encoding: "utf-8")
      end

      def glob(pattern)
        Dir.glob(pattern, base: root_path).select { |path| file?(path) }.sort
      end

      def paths
        @paths ||= begin
          files = []
          Find.find(root_path) do |path|
            if File.directory?(path)
              basename = File.basename(path)
              if SKIP_DIRECTORIES.include?(basename) && path != root_path
                Find.prune
              else
                next
              end
            end

            files << path.delete_prefix("#{root_path}/")
          end
          files.sort
        end
      end

      private

      def absolute(path)
        File.join(root_path, path)
      end
    end

    class FileListRepository
      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
      attr_reader :paths

      def initialize(file_list)
        @paths = Array(file_list).map(&:to_s).uniq.sort
      end

      def file?(path)
        path_set.include?(path)
      end

      def directory?(path)
        prefix = "#{path}/"
        @paths.any? { |entry| entry.start_with?(prefix) }
      end

      def read(_path)
        nil
      end

      def glob(pattern)
        @paths.select { |path| File.fnmatch?(pattern, path, GLOB_FLAGS) }
      end

      private

      def path_set
        @path_set ||= @paths.to_set
      end
    end

    class GithubRepository
      attr_reader :project

      def initialize(project)
        @project = project
      end

      def file?(path)
        path_set.include?(path)
      end

      def directory?(path)
        prefix = "#{path}/"
        path_set.any? { |entry| entry.start_with?(prefix) }
      end

      def read(path)
        return unless file?(path)

        project.client.file_content(project.full_name, path:, ref:)&.force_encoding("UTF-8")&.scrub("")
      rescue GithubClient::NotFoundError
        nil
      end

      def glob(pattern)
        matcher = File::FNM_PATHNAME | File::FNM_EXTGLOB
        paths.select { |path| File.fnmatch?(pattern, path, matcher) }
      end

      def paths
        @paths ||= Array(tree.tree).select { |item| item.type == "blob" }.map(&:path).sort
      end

      private

      def path_set
        @path_set ||= paths.to_set
      end

      def ref
        @ref ||= project.default_branch || "main"
      end

      def tree
        @tree ||= project.client.tree(project.full_name, ref, recursive: true)
      end
    end
  end
end
