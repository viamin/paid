# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "stringio"
require "time"
require "uri"
require "zlib"

# Read-only lookups against the upstream registries that publish the versions
# Paid pins. Each method answers "what is current upstream, and when was it
# published" — the publish time is what lets callers apply a quarantine before
# adopting a release.
#
# Responses are memoized per process because a single bin/update run asks the
# same registry for the same package several times.
module UpstreamRegistries
  Release = Struct.new(:version, :published_at, :assets, keyword_init: true) do
    # GitHub only publishes a `digest` for assets uploaded since the feature
    # existed, so releases predating it report none. Falling back to hashing the
    # asset keeps older projects updatable; writing the empty digest through
    # would silently blank the checksum every image build verifies against.
    def checksum_for(asset_name)
      asset = assets.fetch(asset_name) do
        raise KeyError, "Asset #{asset_name} not published in release #{version}"
      end

      checksum = asset[:digest]
      checksum = UpstreamRegistries.asset_checksum(asset.fetch(:url)) if checksum.to_s.empty?

      unless checksum.match?(/\A[0-9a-f]{64}\z/)
        raise "Resolved a malformed SHA-256 for #{asset_name} in release #{version}"
      end

      checksum
    end
  end

  NPM_REGISTRY = "https://registry.npmjs.org"
  GITHUB_API = "https://api.github.com"
  RUBYGEMS_API = "https://rubygems.org/api"
  DOCKER_HUB_API = "https://hub.docker.com/v2"
  PGDG_APT = "https://apt.postgresql.org/pub/repos/apt"
  RUBY_RELEASE_INDEX = "https://cache.ruby-lang.org/pub/ruby/index.txt"
  NODE_RELEASE_INDEX = "https://nodejs.org/dist/index.json"
  GO_RELEASE_INDEX = "https://go.dev/dl/?mode=json&include=all"

  # PGDG builds the same upstream release for several architectures; Paid's
  # images build for both, so a resolved package must exist for both.
  PGDG_ARCHITECTURES = %w[amd64 arm64].freeze

  class << self
    # Only reached for releases GitHub publishes no digest for; memoized because
    # a group asks for the same asset once per file it is pinned in.
    def asset_checksum(url)
      cache(:asset_checksum, url) do
        # Worth saying out loud: a digest the publisher attests to is evidence,
        # while one derived here is only a record of what this machine received.
        warn "  ⚠ #{File.basename(URI(url).path)}: release publishes no digest; " \
             "deriving SHA-256 from the downloaded asset"
        Digest::SHA256.hexdigest(fetch_body(url))
      end
    end

    # One-off JSON documents that are not a package registry — the vendored LID
    # plugin manifest — so callers do not have to reach into private internals.
    def json(url)
      fetch_json(url)
    end

    def npm(package)
      data = npm_registry(package)
      version = data.dig("dist-tags", "latest")

      Release.new(version: version, published_at: Time.parse(data.dig("time", version)), assets: {})
    end

    def npm_publish_time(package, version)
      timestamp = npm_registry(package).dig("time", version)
      timestamp && Time.parse(timestamp)
    rescue StandardError
      nil
    end

    def github_release(repo, strip_leading_v: false)
      cache(:github, repo) do
        payload = fetch_json(
          "#{GITHUB_API}/repos/#{repo}/releases/latest",
          headers: { "Accept" => "application/vnd.github+json" }
        )
        tag = payload.fetch("tag_name")
        assets = payload.fetch("assets").to_h do |asset|
          [
            asset.fetch("name"),
            {
              digest: asset["digest"].to_s.delete_prefix("sha256:"),
              url: asset.fetch("browser_download_url")
            }
          ]
        end

        Release.new(
          version: strip_leading_v ? tag.delete_prefix("v") : tag,
          published_at: Time.parse(payload.fetch("published_at")),
          assets: assets
        )
      end
    end

    def rubygems(gem_name)
      cache(:rubygems, gem_name) do
        version = fetch_json("#{RUBYGEMS_API}/v1/versions/#{gem_name}/latest.json").fetch("version")

        Release.new(version: version, published_at: gem_publish_time(gem_name, version), assets: {})
      end
    end

    def gem_publish_time(gem_name, version)
      payload = fetch_json("#{RUBYGEMS_API}/v2/rubygems/#{gem_name}/versions/#{version}.json")
      Time.parse(payload.fetch("created_at"))
    rescue StandardError
      nil
    end

    # Docker Hub paginates tags, so ask only for the ones sharing the major
    # version prefix rather than walking the whole tag list. Returns versions
    # oldest-first, mapped to when the tag was last pushed, so callers can apply
    # the same publish-age quarantine they apply to every other source.
    def docker_hub_versions(repository, major:)
      cache(:docker_hub, "#{repository}@#{major}") do
        docker_hub_tags("#{DOCKER_HUB_API}/repositories/#{repository}/tags?page_size=100&name=#{major}.")
          .select { |result| result.fetch("name").match?(/\A#{Regexp.escape(major)}\.\d+\z/) }
          .sort_by { |result| result.fetch("name").split(".").map(&:to_i) }
          .to_h { |result| [ result.fetch("name"), parse_time(result["last_updated"]) ] }
      end
    end

    # Best-effort, and deliberately shallow: this only feeds a "a newer major
    # exists" notice, Docker Hub returns most-recently-updated tags first, and an
    # unfiltered listing runs to thousands of tags. Walking all of them would add
    # ten round trips to every run to answer a question one page already answers.
    def docker_hub_majors(repository)
      cache(:docker_hub_majors, repository) do
        docker_hub_tags(
          "#{DOCKER_HUB_API}/repositories/#{repository}/tags?page_size=100",
          page_limit: 1,
          warn_on_truncation: false
        )
          .map { |result| result.fetch("name") }
          .grep(/\A\d+\.\d+\z/)
          .map { |version| version.split(".").first.to_i }
          .uniq
          .sort
      end
    end

    # The PGDG package revision is not derivable from the upstream version --
    # the same release can be published as `+1` for one version and `+2` for
    # the next -- so the real package version is read from the package index.
    # Returns nil when the release has no package for every architecture Paid
    # builds, which is the signal to leave the pin alone.
    #
    # @spec TOOLCHAIN-PIN-021
    # @spec TOOLCHAIN-PIN-022
    def pgdg_client_version(distribution:, major:, upstream_version:)
      resolved = PGDG_ARCHITECTURES.map do |architecture|
        pgdg_package_versions(distribution: distribution, architecture: architecture, major: major)
          .find { |version| version.start_with?("#{upstream_version}-") }
      end

      return nil if resolved.any?(&:nil?)
      return nil unless resolved.uniq.one?

      resolved.first
    end

    def ruby_versions(series:)
      cache(:ruby_index, series) do
        fetch_text(RUBY_RELEASE_INDEX)
          .lines
          .filter_map { |line| line.split(/\s+/).first&.delete_prefix("ruby-") }
          .grep(/\A#{Regexp.escape(series)}\.\d+\z/)
          .uniq
          .sort_by { |version| version.split(".").map(&:to_i) }
      end
    end

    def node_versions(major:)
      cache(:node_index, major) do
        fetch_json(NODE_RELEASE_INDEX)
          .map { |release| release.fetch("version").delete_prefix("v") }
          .grep(/\A#{Regexp.escape(major)}\.\d+\.\d+\z/)
          .uniq
          .sort_by { |version| version.split(".").map(&:to_i) }
      end
    end

    def go_versions(series:)
      cache(:go_index, series) do
        fetch_json(GO_RELEASE_INDEX)
          .select { |release| release["stable"] }
          .map { |release| release.fetch("version").delete_prefix("go") }
          .grep(/\A#{Regexp.escape(series)}\.\d+\z/)
          .uniq
          .sort_by { |version| version.split(".").map(&:to_i) }
      end
    end

    private

    # Docker Hub paginates tags, and a repository can publish more variant tags
    # (alpine, bookworm, ...) than fit on one page. Reading only the first page
    # would silently hide the newest release behind older variants.
    def docker_hub_tags(url, page_limit: 10, warn_on_truncation: true)
      results = []
      pages = 0

      while url && pages < page_limit
        payload = fetch_json(url)
        results.concat(payload.fetch("results"))
        url = payload["next"]
        pages += 1
      end

      warn "  ⚠ Docker Hub tag listing truncated at #{page_limit} pages" if url && warn_on_truncation

      results
    end

    def npm_registry(package)
      cache(:npm, package) { fetch_json("#{NPM_REGISTRY}/#{package.gsub("/", "%2F")}") }
    end

    def pgdg_package_versions(distribution:, architecture:, major:)
      cache(:pgdg, "#{distribution}/#{architecture}/#{major}") do
        index = fetch_gzip(
          "#{PGDG_APT}/dists/#{distribution}-pgdg/main/binary-#{architecture}/Packages.gz"
        )
        parse_package_versions(index, "postgresql-client-#{major}")
      end
    end

    # Debian package indexes are stanzas of `Field: value` separated by blank
    # lines, so track the package name and take the Version from its stanza.
    def parse_package_versions(index, package_name)
      versions = []
      current = nil

      index.each_line do |line|
        case line
        when /\APackage:\s*(\S+)/ then current = Regexp.last_match(1)
        when /\AVersion:\s*(\S+)/ then versions << Regexp.last_match(1) if current == package_name
        end
      end

      versions
    end

    def parse_time(value)
      value && Time.parse(value)
    rescue ArgumentError, TypeError
      nil
    end

    def cache(namespace, key)
      @cache ||= {}
      store = (@cache[namespace] ||= {})
      return store[key] if store.key?(key)

      store[key] = yield
    end

    def fetch_json(uri_string, headers: {})
      JSON.parse(fetch_text(uri_string, headers: headers))
    end

    def fetch_gzip(uri_string)
      Zlib::GzipReader.new(StringIO.new(fetch_body(uri_string))).read
    end

    def fetch_text(uri_string, headers: {})
      fetch_body(uri_string, headers: headers)
    end

    def fetch_body(uri_string, headers: {}, redirects_remaining: 3)
      uri = URI(uri_string)
      # Every source here is HTTPS, and what comes back becomes a pinned version
      # or the checksum an image build verifies against. Following a redirect
      # down to plaintext would hand an on-path attacker the choice of those
      # bytes, so refuse the downgrade instead of silently accepting it.
      raise "Refusing non-HTTPS request to #{uri}" unless uri.scheme == "https"

      request = Net::HTTP::Get.new(uri)
      headers.each { |name, value| request[name] = value }

      response = Net::HTTP.start(
        uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30
      ) { |http| http.request(request) }

      if response.is_a?(Net::HTTPRedirection) && redirects_remaining.positive?
        return fetch_body(
          URI.join(uri_string, response["location"]).to_s,
          headers: headers,
          redirects_remaining: redirects_remaining - 1
        )
      end
      raise "Failed to fetch #{uri}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
  end
end
