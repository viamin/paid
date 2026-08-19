# frozen_string_literal: true

# Declarative registry of the third-party version pins Paid owns.
#
# A single logical pin is written into several files, each in its own idiom —
# an `ARG` in the devcontainer image, a bare `RUN VAR=` in the agent image, a
# service `image:` in a workflow. Declaring those locations once, as data, is
# what lets bin/update rewrite a whole consistency group and lets
# spec/config/toolchain_pins_spec.rb fail the build when a file drifts
# past its own pattern.
#
# Every pattern captures exactly three groups: the text before the value, the
# value itself, and the text after it. bin/update rewrites group 2 in place.
#
# @spec TOOLCHAIN-PIN-001
# @spec TOOLCHAIN-PIN-002
# @spec TOOLCHAIN-PIN-003
module ToolchainPins
  AGENT_DOCKERFILE = "docker/agent/Dockerfile"
  DEVCONTAINER_DOCKERFILE = ".devcontainer/Dockerfile"
  PRODUCTION_DOCKERFILE = "Dockerfile"

  # Where a pinned PostgreSQL client package is installed, and which PGDG
  # distribution suite each image resolves it from. The suite is a property of
  # the image's base OS, so it belongs beside the path rather than being
  # inferred at update time.
  #
  # @spec TOOLCHAIN-PIN-021
  POSTGRES_CLIENT_DISTRIBUTIONS = {
    DEVCONTAINER_DOCKERFILE => "bookworm",
    PRODUCTION_DOCKERFILE => "trixie",
    AGENT_DOCKERFILE => "noble"
  }.freeze

  # Compose files and workflow service blocks that pin the PostgreSQL server
  # image. pr-screenshots.yml pulls through an ECR mirror, so the pattern
  # tolerates a registry prefix.
  POSTGRES_IMAGE_PATHS = [
    ".devcontainer/compose.yaml",
    "docker-compose.yml",
    ".github/workflows/ci.yml",
    ".github/workflows/system_tests.yml",
    ".github/workflows/test_prof.yml",
    ".github/workflows/pr-screenshots.yml",
    ".github/workflows/pr-screenshots-publish.yml",
    ".github/workflows/ephemeral_tests.yml"
  ].freeze

  POSTGRES_IMAGE_PATTERN = %r{^(\s*image:\s*(?:[\w.\-]+/)*postgres:)(\d+(?:\.\d+)+)(\s*)$}
  POSTGRES_CLIENT_PATTERN = /(postgresql-client-\d+=)(\S+?)(\s|$)/

  # Agent CLI versions are declared by agent-harness installation contracts and
  # read at build time, so Paid holds no pin to rewrite. These packages exist in
  # the registry only so bin/update can report a contract that lags upstream.
  #
  # @spec TOOLCHAIN-PIN-030
  # @spec TOOLCHAIN-PIN-031
  CONTRACT_PACKAGES = {
    "claude" => "@anthropic-ai/claude-code",
    "codex" => "@openai/codex",
    "opencode" => "opencode-ai",
    "kilocode" => "@kilocode/cli",
    "omp" => "@oh-my-pi/pi-coding-agent",
    "pi" => "@mariozechner/pi-coding-agent",
    "gemini" => "@google/gemini-cli",
    "copilot" => "@github/copilot"
  }.freeze

  # The gem whose release determines every contract-owned version above.
  AGENT_HARNESS_GEM = "agent-harness"
  AGENT_HARNESS_PATTERN = /^(gem "agent-harness", ")([^"]+)(")$/

  # Devcontainer defaults that duplicate the omp contract. They exist because
  # the installer must run before bundler is available, so they are reconciled
  # against the contract rather than against upstream.
  #
  # @spec TOOLCHAIN-PIN-034
  OH_MY_PI_INSTALLER = ".devcontainer/install-oh-my-pi.sh"
  OH_MY_PI_BUN_PATTERN = /^(BUN_VERSION="\$\{BUN_VERSION:-)([^}]+)(\}")$/
  OH_MY_PI_PACKAGE_PATTERN = /^(OMP_PACKAGE="\$\{OMP_PACKAGE:-.*@)([^@}]+)(\}")$/

  # Language runtimes are reported, never rewritten: moving them is a migration
  # with build, gem, and CI consequences.
  #
  # @spec TOOLCHAIN-PIN-040
  TOOL_VERSIONS_FILE = ".tool-versions"
  REPORT_ONLY_RUNTIMES = %w[ruby nodejs golang].freeze

  # One occurrence of a pin in one file.
  Entry = Struct.new(:path, :pattern, :kind, :arch, :distribution, keyword_init: true) do
    def exist?(root)
      root.join(path).exist?
    end

    def matches?(root)
      !current_value(root).nil?
    end

    def current_value(root)
      return nil unless exist?(root)

      contents(root).match(pattern)&.captures&.at(1)
    end

    def occurrences(root)
      contents(root).scan(pattern).size
    end

    def label
      [ kind, arch, distribution ].compact.join(" ")
    end

    private

    def contents(root)
      root.join(path).read
    end
  end

  # A set of entries across files that must always carry the same value.
  Group = Struct.new(:name, :ownership, :source, :assets, :entries, keyword_init: true) do
    def version_entries
      entries.select { |entry| entry.kind == :version }
    end

    def checksum_entries
      entries.select { |entry| entry.kind == :checksum }
    end

    def client_package_entries
      entries.select { |entry| entry.kind == :client_package }
    end

    # Paths the registry names that are no longer on disk. A deleted file is a
    # registry that has drifted from the repository, so the group is held rather
    # than partially rewritten — updating the survivors would leave the group
    # inconsistent, which is the exact failure the group exists to prevent.
    #
    # @spec TOOLCHAIN-PIN-002
    def missing_paths(root)
      entries.map(&:path).uniq.reject { |path| root.join(path).exist? }
    end

    # Entries whose file is present but whose pattern no longer finds anything.
    # This is the same drift as a deleted file — the registry has fallen out of
    # step with the repository — and it must be caught before the value is read,
    # because callers reasonably assume a matched entry yields a version string.
    #
    # @spec TOOLCHAIN-PIN-002
    def unmatched_entries(root)
      entries.select { |entry| entry.exist?(root) && !entry.matches?(root) }
    end

    # @spec TOOLCHAIN-PIN-003
    def current_versions(root)
      version_entries.to_h { |entry| [ entry.path, entry.current_value(root) ] }
    end

    def current_version(root)
      current_versions(root).values.uniq.first
    end

    # False when the group's files disagree with each other. Such a group still
    # needs rewriting even when its newest file already matches upstream, so
    # callers must not decide "up to date" from a single collapsed value.
    #
    # @spec TOOLCHAIN-PIN-003
    def consistent?(root)
      current_versions(root).values.uniq.size <= 1
    end

    def current_checksums(root)
      checksum_entries.group_by(&:arch).transform_values do |arch_entries|
        arch_entries.to_h { |entry| [ entry.path, entry.current_value(root) ] }
      end
    end

    def checksums?
      checksum_entries.any?
    end
  end

  class << self
    def groups
      @groups ||= [ yarn_group, ast_grep_group, scc_group, rathole_group, rtk_group,
                    codegraph_group, postgresql_group ].freeze
    end

    def group(name)
      groups.find { |candidate| candidate.name == name } ||
        raise(KeyError, "Unknown toolchain pin group: #{name}")
    end

    def paid_owned_groups
      groups.select { |candidate| candidate.ownership == :paid }
    end

    def contract_packages
      CONTRACT_PACKAGES
    end

    private

    # Yarn's pin also lives in package.json's packageManager field, which
    # bin/update rewrites as JSON rather than by pattern.
    def yarn_group
      Group.new(
        name: "yarn",
        ownership: :paid,
        source: { type: :npm, package: "yarn" },
        assets: {},
        entries: [
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*&& corepack prepare yarn@)(\S+)( --activate\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(RUN corepack enable && corepack prepare yarn@)(\S+)( --activate\s*)$/,
            kind: :version
          )
        ]
      )
    end

    # bin/install-ast-grep keeps a version-keyed checksum table that bin/update
    # rewrites separately; only its default-version line is a simple pin.
    def ast_grep_group
      Group.new(
        name: "ast-grep",
        ownership: :paid,
        source: { type: :github_release, repo: "ast-grep/ast-grep", strip_leading_v: false },
        assets: {
          amd64: "app-x86_64-unknown-linux-gnu.zip",
          arm64: "app-aarch64-unknown-linux-gnu.zip"
        },
        entries: [
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(RUN AST_GREP_VERSION=)(\S+)( \\\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*amd64\) RUST_TRIPLE="x86_64-unknown-linux-gnu"; EXPECTED_CHECKSUM=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*arm64\) RUST_TRIPLE="aarch64-unknown-linux-gnu"; EXPECTED_CHECKSUM=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(ARG AST_GREP_VERSION=)(\S+)(\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(\s*amd64\) rust_triple="x86_64-unknown-linux-gnu"; checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(\s*arm64\) rust_triple="aarch64-unknown-linux-gnu"; checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          )
        ]
      )
    end

    def scc_group
      Group.new(
        name: "scc",
        ownership: :paid,
        source: { type: :github_release, repo: "boyter/scc", strip_leading_v: true },
        assets: {
          amd64: "scc_Linux_x86_64.tar.gz",
          arm64: "scc_Linux_arm64.tar.gz"
        },
        entries: [
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(RUN SCC_VERSION=)(\S+)( \\\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*amd64\) SCC_ARCH="x86_64"; EXPECTED_CHECKSUM=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*arm64\) SCC_ARCH="arm64"; EXPECTED_CHECKSUM=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(ARG SCC_VERSION=)(\S+)(\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(\s*amd64\) scc_arch="x86_64"; checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(\s*arm64\) scc_arch="arm64"; checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          )
        ]
      )
    end

    # rathole is the only binary pinned in all three images. The devcontainer
    # and rtk blocks share `asset=`/`checksum=` variable names, so these
    # patterns anchor on the asset filename to stay unambiguous.
    #
    # @spec TOOLCHAIN-PIN-010
    # @spec TOOLCHAIN-PIN-011
    def rathole_group
      Group.new(
        name: "rathole",
        ownership: :paid,
        source: { type: :github_release, repo: "rathole-org/rathole", strip_leading_v: true },
        assets: {
          amd64: "rathole-x86_64-unknown-linux-gnu.zip",
          arm64: "rathole-aarch64-unknown-linux-musl.zip"
        },
        entries: [
          Entry.new(
            path: PRODUCTION_DOCKERFILE,
            pattern: /^(ARG RATHOLE_VERSION=)(\S+)(\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: PRODUCTION_DOCKERFILE,
            pattern: /^(\s*amd64\) rathole_asset="rathole-[^"]+"; rathole_checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: PRODUCTION_DOCKERFILE,
            pattern: /^(\s*arm64\) rathole_asset="rathole-[^"]+"; rathole_checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(ARG RATHOLE_VERSION=)(\S+)(\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(\s*amd64\) asset="rathole-[^"]+"; checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(\s*arm64\) asset="rathole-[^"]+"; checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(RUN RATHOLE_VERSION=)(\S+)( \\\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*amd64\) RATHOLE_ASSET="rathole-[^"]+"; EXPECTED_CHECKSUM=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*arm64\) RATHOLE_ASSET="rathole-[^"]+"; EXPECTED_CHECKSUM=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          )
        ]
      )
    end

    # @spec TOOLCHAIN-PIN-010
    # @spec TOOLCHAIN-PIN-011
    def rtk_group
      Group.new(
        name: "rtk",
        ownership: :paid,
        source: { type: :github_release, repo: "rtk-ai/rtk", strip_leading_v: true },
        assets: {
          amd64: "rtk-x86_64-unknown-linux-musl.tar.gz",
          arm64: "rtk-aarch64-unknown-linux-gnu.tar.gz"
        },
        entries: [
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(ARG RTK_VERSION=)(\S+)(\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(\s*amd64\) asset="rtk-[^"]+"; checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(\s*arm64\) asset="rtk-[^"]+"; checksum=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(RUN RTK_VERSION=)(\S+)( \\\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*amd64\) RTK_ASSET="rtk-[^"]+"; EXPECTED_CHECKSUM=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :amd64
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(\s*arm64\) RTK_ASSET="rtk-[^"]+"; EXPECTED_CHECKSUM=")([0-9a-f]+)(".*)$/,
            kind: :checksum, arch: :arm64
          )
        ]
      )
    end

    # npm-sourced, so there is no checksum to carry alongside the version.
    #
    # @spec TOOLCHAIN-PIN-010
    def codegraph_group
      Group.new(
        name: "codegraph",
        ownership: :paid,
        source: { type: :npm, package: "@colbymchenry/codegraph" },
        assets: {},
        entries: [
          Entry.new(
            path: DEVCONTAINER_DOCKERFILE,
            pattern: /^(ARG CODEGRAPH_VERSION=)(\S+)(\s*)$/,
            kind: :version
          ),
          Entry.new(
            path: AGENT_DOCKERFILE,
            pattern: /^(RUN CODEGRAPH_VERSION=)(\S+)( \\\s*)$/,
            kind: :version
          )
        ]
      )
    end

    # The server image pin drives the client package pin: pg_dump refuses to
    # dump from a server newer than itself, so every image must install a client
    # built from the same upstream release.
    #
    # @spec TOOLCHAIN-PIN-020
    def postgresql_group
      image_entries = POSTGRES_IMAGE_PATHS.map do |path|
        Entry.new(path: path, pattern: POSTGRES_IMAGE_PATTERN, kind: :version)
      end

      client_entries = POSTGRES_CLIENT_DISTRIBUTIONS.map do |path, distribution|
        Entry.new(
          path: path,
          pattern: POSTGRES_CLIENT_PATTERN,
          kind: :client_package,
          distribution: distribution
        )
      end

      Group.new(
        name: "postgresql",
        ownership: :paid,
        source: { type: :docker_hub, repository: "library/postgres" },
        assets: {},
        entries: image_entries + client_entries
      )
    end
  end
end
