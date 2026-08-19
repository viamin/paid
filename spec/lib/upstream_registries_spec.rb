# frozen_string_literal: true

require "rails_helper"
require "zlib"
require "stringio"
require Rails.root.join("scripts/lib/upstream_registries")

RSpec.describe UpstreamRegistries, :no_db do
  # Each example gets a clean memo table; the module caches per process so a
  # single bin/update run asks each registry once.
  before { described_class.instance_variable_set(:@cache, {}) }

  def gzip(body)
    io = StringIO.new(+"", "wb")
    Zlib::GzipWriter.new(io).tap { |writer| writer.write(body) }.close
    io.string
  end

  def packages_index(package:, versions:)
    versions.map { |version| "Package: #{package}\nVersion: #{version}\nArchitecture: amd64\n\n" }.join
  end

  describe ".github_release" do
    let(:release_url) { "https://api.github.com/repos/acme/tool/releases/latest" }

    def stub_release(assets)
      stub_request(:get, release_url).to_return(
        status: 200,
        body: {
          tag_name: "v2.3.4",
          published_at: "2026-01-02T03:04:05Z",
          assets: assets
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    end

    it "strips a leading v from the tag when the pin does not carry one" do
      stub_release([])

      expect(described_class.github_release("acme/tool", strip_leading_v: true).version).to eq("2.3.4")
    end

    it "keeps the tag verbatim when the pin carries it" do
      stub_release([])

      expect(described_class.github_release("acme/tool").version).to eq("v2.3.4")
    end

    # @spec TOOLCHAIN-PIN-011
    it "uses the digest GitHub publishes for the asset" do
      digest = "a" * 64
      stub_release([ { name: "tool.zip", digest: "sha256:#{digest}", browser_download_url: "https://example.test/tool.zip" } ])

      release = described_class.github_release("acme/tool")

      expect(release.checksum_for("tool.zip")).to eq(digest)
    end

    # Releases predating GitHub's asset digests report none. Writing that empty
    # value through would blank the checksum every image build verifies against.
    #
    # @spec TOOLCHAIN-PIN-011
    it "hashes the asset itself when GitHub publishes no digest" do
      stub_release([ { name: "tool.zip", digest: nil, browser_download_url: "https://example.test/tool.zip" } ])
      stub_request(:get, "https://example.test/tool.zip").to_return(status: 200, body: "payload")

      release = described_class.github_release("acme/tool")

      expect(release.checksum_for("tool.zip")).to eq(Digest::SHA256.hexdigest("payload"))
    end

    # @spec TOOLCHAIN-PIN-011
    it "refuses a checksum that is not a SHA-256 digest" do
      stub_release([ { name: "tool.zip", digest: "sha256:nonsense", browser_download_url: "https://example.test/tool.zip" } ])

      release = described_class.github_release("acme/tool")

      expect { release.checksum_for("tool.zip") }.to raise_error(/malformed SHA-256/)
    end

    it "raises when the release does not publish the asset the pin needs" do
      stub_release([ { name: "other.zip", digest: "sha256:#{"b" * 64}", browser_download_url: "https://example.test/other.zip" } ])

      release = described_class.github_release("acme/tool")

      expect { release.checksum_for("tool.zip") }.to raise_error(KeyError, /not published/)
    end
  end

  describe ".docker_hub_versions" do
    # @spec TOOLCHAIN-PIN-020
    it "returns only the requested major, ordered oldest first, with publish times" do
      stub_request(:get, "https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&name=16.")
        .to_return(
          status: 200,
          body: {
            results: [
              { name: "16.15", last_updated: "2026-08-16T07:08:07Z" },
              { name: "16.9", last_updated: "2026-01-16T07:08:07Z" },
              { name: "16.14", last_updated: "2026-08-05T07:08:30Z" },
              { name: "16.15-alpine", last_updated: "2026-08-16T07:08:07Z" }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      versions = described_class.docker_hub_versions("library/postgres", major: "16")

      expect(versions.keys).to eq(%w[16.9 16.14 16.15])
      expect(versions.fetch("16.15")).to eq(Time.parse("2026-08-16T07:08:07Z"))
    end
  end

  # The bytes these lookups return become pinned versions and the checksums an
  # image build verifies against, so a redirect down to plaintext would let an
  # on-path attacker choose them.
  #
  # @spec TOOLCHAIN-PIN-011
  describe "transport safety" do
    it "refuses a plaintext request outright" do
      expect { described_class.json("http://registry.test/doc.json") }
        .to raise_error(/Refusing non-HTTPS/)
    end

    it "refuses a redirect that downgrades to plaintext" do
      stub_request(:get, "https://registry.test/doc.json")
        .to_return(status: 302, headers: { "Location" => "http://registry.test/doc.json" })

      expect { described_class.json("https://registry.test/doc.json") }
        .to raise_error(/Refusing non-HTTPS/)
    end

    it "follows a redirect that stays on HTTPS" do
      stub_request(:get, "https://registry.test/doc.json")
        .to_return(status: 302, headers: { "Location" => "https://cdn.test/doc.json" })
      stub_request(:get, "https://cdn.test/doc.json")
        .to_return(status: 200, body: { ok: true }.to_json)

      expect(described_class.json("https://registry.test/doc.json")).to eq("ok" => true)
    end
  end

  describe ".docker_hub_majors" do
    # @spec TOOLCHAIN-PIN-023
    it "reports the distinct major versions the repository publishes" do
      stub_request(:get, "https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100")
        .to_return(
          status: 200,
          body: {
            results: [
              { name: "18.6" }, { name: "17.11" }, { name: "16.15" }, { name: "latest" }, { name: "16-alpine" }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect(described_class.docker_hub_majors("library/postgres")).to eq([ 16, 17, 18 ])
    end
  end

  # Docker Hub paginates, and a repository publishes more variant tags (alpine,
  # bookworm, ...) than fit on one page. Reading only the first page would hide
  # the newest release behind older variants and report "up to date" forever.
  #
  # @spec TOOLCHAIN-PIN-020
  describe ".docker_hub_versions pagination" do
    it "follows pages so a release beyond the first is not missed" do
      first = "https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&name=16."
      stub_request(:get, first).to_return(
        status: 200,
        body: {
          next: "https://hub.docker.com/v2/repositories/library/postgres/tags?page=2&page_size=100&name=16.",
          results: [ { name: "16.14", last_updated: "2026-08-05T07:08:30Z" },
                     { name: "16.15-alpine", last_updated: "2026-08-16T07:08:07Z" } ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      stub_request(:get, "https://hub.docker.com/v2/repositories/library/postgres/tags?page=2&page_size=100&name=16.")
        .to_return(
          status: 200,
          body: { next: nil, results: [ { name: "16.15", last_updated: "2026-08-16T07:08:07Z" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      versions = described_class.docker_hub_versions("library/postgres", major: "16")

      expect(versions.keys).to eq(%w[16.14 16.15])
    end
  end

  describe ".pgdg_client_version" do
    def stub_pgdg(distribution, architecture, body)
      stub_request(
        :get,
        "https://apt.postgresql.org/pub/repos/apt/dists/#{distribution}-pgdg/main/binary-#{architecture}/Packages.gz"
      ).to_return(status: 200, body: gzip(body), headers: { "Content-Type" => "application/gzip" })
    end

    def stub_both_architectures(distribution, versions)
      %w[amd64 arm64].each do |architecture|
        stub_pgdg(distribution, architecture, packages_index(package: "postgresql-client-16", versions: versions))
      end
    end

    # The PGDG revision is not derivable from the upstream version: 16.15 ships
    # as +2 where 16.14 shipped as +1.
    #
    # @spec TOOLCHAIN-PIN-021
    it "returns the package revision PGDG actually published" do
      stub_both_architectures("bookworm", [ "16.15-1.pgdg12+2", "16.14-1.pgdg12+1" ])

      resolved = described_class.pgdg_client_version(
        distribution: "bookworm", major: "16", upstream_version: "16.15"
      )

      expect(resolved).to eq("16.15-1.pgdg12+2")
    end

    # @spec TOOLCHAIN-PIN-022
    it "returns nothing when the release has no package for the distribution" do
      stub_both_architectures("bookworm", [ "16.14-1.pgdg12+1" ])

      resolved = described_class.pgdg_client_version(
        distribution: "bookworm", major: "16", upstream_version: "16.15"
      )

      expect(resolved).to be_nil
    end

    # Paid's images build for both architectures, so a package present on only
    # one of them is not safe to pin.
    #
    # @spec TOOLCHAIN-PIN-022
    it "returns nothing when only one architecture has the package" do
      stub_pgdg("noble", "amd64", packages_index(package: "postgresql-client-16", versions: [ "16.15-1.pgdg24.04+2" ]))
      stub_pgdg("noble", "arm64", packages_index(package: "postgresql-client-16", versions: [ "16.14-1.pgdg24.04+1" ]))

      resolved = described_class.pgdg_client_version(
        distribution: "noble", major: "16", upstream_version: "16.15"
      )

      expect(resolved).to be_nil
    end

    it "ignores versions belonging to a different package" do
      index = packages_index(package: "postgresql-client-17", versions: [ "16.15-1.pgdg12+2" ])
      %w[amd64 arm64].each { |architecture| stub_pgdg("bookworm", architecture, index) }

      resolved = described_class.pgdg_client_version(
        distribution: "bookworm", major: "16", upstream_version: "16.15"
      )

      expect(resolved).to be_nil
    end
  end

  describe ".ruby_versions" do
    # @spec TOOLCHAIN-PIN-040
    it "returns the requested series ordered oldest first" do
      stub_request(:get, "https://cache.ruby-lang.org/pub/ruby/index.txt").to_return(
        status: 200,
        body: [
          "name\turl\tsha256",
          "ruby-3.4.10\thttps://example.test/a\tsha",
          "ruby-3.4.8\thttps://example.test/b\tsha",
          "ruby-3.3.9\thttps://example.test/c\tsha"
        ].join("\n")
      )

      expect(described_class.ruby_versions(series: "3.4")).to eq(%w[3.4.8 3.4.10])
    end
  end

  describe ".go_versions" do
    # @spec TOOLCHAIN-PIN-040
    it "returns the requested series ordered oldest first, ignoring prereleases" do
      stub_request(:get, "https://go.dev/dl/?mode=json&include=all").to_return(
        status: 200,
        body: [
          { version: "go1.26.0", stable: true },
          { version: "go1.25.14", stable: true },
          { version: "go1.25.6", stable: true },
          { version: "go1.25.15rc1", stable: false }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect(described_class.go_versions(series: "1.25")).to eq(%w[1.25.6 1.25.14])
    end
  end

  describe ".node_versions" do
    # @spec TOOLCHAIN-PIN-040
    it "returns the requested major ordered oldest first" do
      stub_request(:get, "https://nodejs.org/dist/index.json").to_return(
        status: 200,
        body: [ { version: "v26.7.0" }, { version: "v24.19.0" }, { version: "v24.18.0" } ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect(described_class.node_versions(major: "24")).to eq(%w[24.18.0 24.19.0])
    end
  end
end
