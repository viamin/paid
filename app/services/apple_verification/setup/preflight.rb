# frozen_string_literal: true

module AppleVerification
  module Setup
    # Read-only macOS worker host preflight. Performs no host state mutation,
    # no guest execution, and no project-code execution; every check has an
    # explicit pass / warn / gap status and a manual operator action the
    # caller renders when the check fails.
    # @spec APPLE-SETUP-001
    # @spec APPLE-SETUP-002
    class Preflight
      Result = Data.define(:id, :status, :detail, :fix) do
        def pass?
          status == :pass
        end

        def warn?
          status == :warn
        end

        def gap?
          status == :gap
        end
      end
      Report = Data.define(:results) do
        def status
          return :gap if results.any?(&:gap?)

          :warn if results.any?(&:warn?)

          :ready
        end

        def passed?
          status == :ready
        end

        def warn?
          status == :warn
        end

        def gapped?
          status == :gap
        end

        def gap_results
          results.select(&:gap?)
        end

        def warn_results
          results.select(&:warn?)
        end

        def ready?
          status == :ready
        end
      end

      DEFAULT_TART_MAJOR = 2
      DEFAULT_MIN_DISK_GIB = 60
      DEFAULT_MIN_MEMORY_PERCENT = 25
      DEFAULT_MAX_ACTIVE_VMS = 1
      DEFAULT_MIN_GUEST_DISK_GIB = 15

      def self.call(...)
        new(...).call
      end

      def initialize(shell: Shell.new, profile_id: nil, account_id: nil,
        approved_image_digests: [],
        host_url: ENV["APPLE_VERIFICATION_HOST_URL"].to_s,
        host_token: ENV["APPLE_VERIFICATION_HOST_TOKEN"].to_s,
        min_disk_gib: DEFAULT_MIN_DISK_GIB,
        min_memory_percent: DEFAULT_MIN_MEMORY_PERCENT,
        max_active_vms: DEFAULT_MAX_ACTIVE_VMS,
        min_guest_disk_gib: DEFAULT_MIN_GUEST_DISK_GIB,
        tart_major: DEFAULT_TART_MAJOR)
        @shell = shell
        @profile_id = profile_id
        @account_id = account_id
        @approved_image_digests = Array(approved_image_digests).map(&:to_s)
        @host_url = host_url
        @host_token = host_token
        @min_disk_gib = min_disk_gib
        @min_memory_percent = min_memory_percent
        @max_active_vms = max_active_vms
        @min_guest_disk_gib = min_guest_disk_gib
        @tart_major = Integer(tart_major)
      end

      def call
        Report.new(results: check_methods.map { |method| send(method) })
      end

      private

      attr_reader :shell, :profile_id, :account_id, :approved_image_digests,
        :host_url, :host_token, :min_disk_gib, :min_memory_percent,
        :max_active_vms, :min_guest_disk_gib, :tart_major

      def check_methods
        [
          :check_virtualization_permission,
          :check_tart_binary,
          :check_softnet,
          :check_approved_image,
          :check_xcode_toolchain,
          :check_simulator_runtimes,
          :check_guest_gui_account,
          :check_host_service_authentication,
          :check_proxy_enforcement,
          :check_capacity
        ]
      end

      Result::IDS = %i[
        virtualization_permission tart_binary softnet approved_image
        xcode_toolchain simulator_runtimes guest_gui_account
        host_service_authentication proxy_enforcement capacity
      ].freeze

      def check_virtualization_permission
        result = shell.run("sysctl", "-n", "kern.hv_vmm_present")
        case result.stdout.to_s.strip
        when "1"
          pass(:virtualization_permission, "sysctl kern.hv_vmm_present=1")
        when "0", ""
          gap(:virtualization_permission,
            "sysctl kern.hv_vmm_present=#{result.stdout.to_s.strip.presence || 'missing'}",
            "Enable Apple virtualization in System Settings → Privacy & Security, then verify with: sysctl kern.hv_vmm_present (must print 1).")
        else
          gap(:virtualization_permission,
            "sysctl kern.hv_vmm_present=#{result.stdout.to_s.strip}",
            "Enable Apple virtualization in System Settings → Privacy & Security, then verify with: sysctl kern.hv_vmm_present (must print 1).")
        end
      end

      def check_tart_binary
        path = shell.command_path("tart")
        if path.blank?
          return gap(:tart_binary, "tart not on PATH",
            "Install Tart via Homebrew: brew install cirruslabs/cli/tart, then verify: tart --version (must report major #{tart_major}).")
        end

        version = shell.run("tart", "--version")
        major = version.stdout.to_s.strip.split(".").first
        if major.to_i >= tart_major && version.success?
          pass(:tart_binary, "tart at #{path} reports major #{major} (#{version.stdout.to_s.strip})")
        else
          gap(:tart_binary, "tart at #{path} reports #{version.stdout.to_s.strip.presence || 'no version'}",
            "Upgrade Tart to major #{tart_major} or later: brew upgrade cirruslabs/cli/tart.")
        end
      end

      def check_softnet
        result = shell.run("tart", "softnet", "status")
        if result.success? && result.stdout.to_s.include?("running")
          pass(:softnet, "tart softnet reports running")
        else
          gap(:softnet, "tart softnet status did not report running",
            "Start Softnet once: sudo tart softnet start, then verify: tart softnet status (must include 'running').")
        end
      end

      def check_approved_image
        vm_names = shell.local_tart_vm_names
        if vm_names.empty?
          return gap(:approved_image,
            "no local Tart VM directories found under #{shell.tart_home_dir}/vms",
            "Clone the immutable image: tart clone <source-image> paid-macos-base, then publish the matching AppleVerificationImage row via the admin UI with the exact digest.")
        end

        match = find_matching_image(vm_names)
        if match
          pass(:approved_image,
            "approved image digest #{match[:approved]} matches local VM #{match[:name]} (sha256:#{match[:computed]})")
        else
          gap(:approved_image,
            "no approved image matched a local Tart VM; approved digests=#{approved_image_digests.inspect}, local VMs=#{vm_names.inspect}",
            "Clone the immutable image: tart clone <source-image> paid-macos-base, then publish the matching AppleVerificationImage row via the admin UI with the exact digest.")
        end
      end

      def check_xcode_toolchain
        path_result = shell.run("xcode-select", "-p")
        unless path_result.success? && path_result.stdout.to_s.strip.present?
          return gap(:xcode_toolchain, "xcode-select -p did not resolve",
            "Install Xcode and run: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer, then accept the license with: sudo xcodebuild -license accept.")
        end

        version_result = shell.run("xcodebuild", "-version")
        if version_result.success? && version_result.stdout.to_s.include?("Xcode")
          pass(:xcode_toolchain, "xcode-select=#{path_result.stdout.to_s.strip}; xcodebuild=#{version_result.stdout.to_s.strip.lines.first.to_s.strip}")
        else
          gap(:xcode_toolchain, "xcodebuild -version failed: #{version_result.stderr.to_s.strip.presence || 'unknown'}",
            "Accept the Xcode license: sudo xcodebuild -license accept, then re-verify with: xcodebuild -version.")
        end
      end

      def check_simulator_runtimes
        result = shell.run("xcrun", "simctl", "list", "runtimes")
        unless result.success?
          return gap(:simulator_runtimes, "xcrun simctl list runtimes failed",
            "Install the Xcode command-line tools: xcode-select --install, then download iOS platform runtimes via Xcode → Settings → Platforms.")
        end

        runtimes = result.stdout_lines.grep(/iOS|tvOS|watchOS|visionOS|macOS/).map(&:strip)
        if runtimes.empty?
          gap(:simulator_runtimes, "no iOS / macOS runtimes installed",
            "Download platform runtimes: xcodebuild -downloadPlatform iOS (repeat for each platform the worker profiles declare).")
        else
          pass(:simulator_runtimes, "runtimes: #{runtimes.size} (#{runtimes.first(3).join('; ')})")
        end
      end

      def check_guest_gui_account
        result = shell.run("dscl", ".", "-list", "/Users")
        unless result.success?
          return warn(:guest_gui_account, "dscl could not enumerate users (#{result.stderr.to_s.strip.presence || 'unknown'})")
        end

        users = result.stdout_lines.map(&:strip).reject(&:empty?)
        candidates = users.select { |name| name.start_with?("paidguest") || name.include?("verification") }
        if candidates.empty?
          gap(:guest_gui_account, "no dedicated non-admin guest account found",
            "Create the dedicated guest account: sudo sysadminctl -addUser paidguest -fullName 'Paid Verification' -UID 555 -GID 20 -shell /bin/zsh (no iCloud or system-account linkage, no admin group); then disable screen locking for that UID with: sudo defaults write /Library/Preferences/com.apple.loginwindow DisableScreenLockOverride -bool YES.")
        else
          pass(:guest_gui_account, "guest account candidates: #{candidates.uniq.join(', ')}")
        end
      end

      def check_host_service_authentication
        if host_url.blank? || host_token.blank?
          return gap(:host_service_authentication,
            "APPLE_VERIFICATION_HOST_URL or APPLE_VERIFICATION_HOST_TOKEN is not set",
            "Register the host service as a launchd daemon, export APPLE_VERIFICATION_HOST_URL (https://macos-worker.internal/lifecycle) and APPLE_VERIFICATION_HOST_TOKEN (the bearer token from /etc/paid/host-token), then re-run preflight.")
        end

        client = AppleVerification::HostClient.new(endpoint: host_url)
        response = client.call(version: AppleVerification::HostService::API_VERSION,
          operation: "readiness", payload: {}, token: host_token)
        if response["cpu"] || response["memory"] || response["disk"]
          pass(:host_service_authentication,
            "host service at #{host_url} authenticated; readiness payload=#{response.keys.sort.join(', ')}")
        else
          gap(:host_service_authentication,
            "host service reachable but readiness payload missing capacity keys",
            "Confirm the host service version is #{AppleVerification::HostService::API_VERSION} and the launchd daemon is running: launchctl print system/com.paid.macos-host.")
        end
      rescue AppleVerification::HostService::AuthenticationError
        gap(:host_service_authentication, "host service rejected the configured bearer token",
          "Rotate the bearer token: bin/paid host-service rotate-token, then export the new APPLE_VERIFICATION_HOST_TOKEN on every web and job process and re-run preflight.")
      rescue StandardError => error
        gap(:host_service_authentication, "host service unreachable: #{error.class.name}: #{error.message}",
          "Confirm the host service is reachable from the control plane: curl -H 'Authorization: Bearer ***' #{host_url} with operation=readiness, then re-run preflight.")
      end

      def check_proxy_enforcement
        if host_url.blank? || host_token.blank?
          return warn(:proxy_enforcement, "host service not configured; proxy enforcement cannot be validated")
        end

        client = AppleVerification::HostClient.new(endpoint: host_url)
        response = client.call(version: AppleVerification::HostService::API_VERSION,
          operation: "readiness", payload: {}, token: host_token)
        network = response["network"] || {}
        proxy = network["proxy_relay"] || network["proxyRelay"] || network["egress_proxy"]
        if proxy.to_s.strip == "paid-egress"
          pass(:proxy_enforcement, "host service declares proxy relay=#{proxy}")
        else
          gap(:proxy_enforcement, "host service did not declare a Paid-controlled proxy relay",
            "Wire the Tart network profile to the Paid egress proxy (proxy-relay=paid-egress) in the host service config, then re-run preflight.")
        end
      rescue StandardError => error
        warn(:proxy_enforcement, "proxy enforcement could not be inspected: #{error.class.name}: #{error.message}")
      end

      def check_capacity
        disk = read_disk_gib
        memory = read_memory_percent
        active = read_active_vm_count

        disk_result =
          if disk.nil?
            warn(:capacity, "could not determine free host disk via df -g")
          elsif disk < min_disk_gib
            gap(:capacity, "free host disk #{disk} GiB < operator minimum #{min_disk_gib} GiB",
              "Free #{min_disk_gib - disk} GiB on the worker host to satisfy the #{min_disk_gib} GiB operator minimum (clean up Tart images, derived data, or other large directories); confirm with: df -g /.")
          else
            pass(:capacity, "free host disk #{disk} GiB ≥ #{min_disk_gib} GiB")
          end

        memory_result =
          if memory.nil?
            warn(:capacity, "could not determine host memory pressure via vm_stat or host service readiness payload")
          elsif memory < min_memory_percent
            gap(:capacity, "free host memory #{memory}% < operator minimum #{min_memory_percent}%",
              "Stop other workloads on the worker host or raise the operator minimum (paid.apple_worker.admission.min_memory_percent) after confirming the additional headroom is real; verify with: vm_stat | awk '/free/ {print $3}'.")
          else
            pass(:capacity, "free host memory #{memory}% ≥ #{min_memory_percent}%")
          end

        vms_result =
          if active > max_active_vms
            gap(:capacity, "#{active} active Apple VMs > operator maximum #{max_active_vms}",
              "Destroy the surplus VMs: bin/paid apple-worker reconcile --destroy-orphans, then re-run preflight.")
          else
            pass(:capacity, "#{active} active Apple VM(s) ≤ #{max_active_vms}")
          end

        [ disk_result, memory_result, vms_result ].compact.find(&:gap?) || [ disk_result, memory_result, vms_result ].compact.find(&:warn?) || disk_result
      end

      def read_disk_gib
        result = shell.run("df", "-g", "/")
        return nil unless result.success?

        line = result.stdout_lines.find { |row| row.start_with?("/dev/") }
        return nil unless line

        parts = line.split
        raw = parts[3].to_s
        raw.to_i if raw.match?(/\A\d+(?:\.\d+)?\z/)
      end

      # Prefer the host service's readiness payload (`memory.free_percent`,
      # computed against the full physical memory) over a local `vm_stat`
      # parse. `vm_stat`'s `Pages free + active + inactive` sum excludes
      # wired-down, compressed, and compressor-occupied pages that
      # routinely account for several GiB of working set on M-series
      # hosts, so the local parse can overstate free memory by ~20
      # percentage points and accept hosts the host service would flag.
      # When the host service is configured but does not publish the
      # field (older host builds) fall back to vm_stat so the preflight
      # still produces a result.
      def read_memory_percent
        readiness = readiness_payload
        if readiness
          free = readiness.dig("memory", "free_percent")
          return free.to_f.round if free
        end

        read_memory_percent_from_vm_stat
      end

      def read_memory_percent_from_vm_stat
        result = shell.run("vm_stat")
        return nil unless result.success?

        free_pages = result.stdout_lines.find { |row| row.start_with?("Pages free:") }
        return nil unless free_pages

        free = free_pages.split[2].to_i
        active = result.stdout_lines.find { |row| row.start_with?("Pages active:") }&.split&.[](2).to_i
        inactive = result.stdout_lines.find { |row| row.start_with?("Pages inactive:") }&.split&.[](2).to_i
        total = free + active.to_i + inactive.to_i
        return nil if total.zero?

        ((free.to_f / total) * 100).round
      end

      # Memoised readiness payload fetch. Returns nil when the host
      # service is not configured (no URL or token) or when the fetch
      # raises — capacity falls back to vm_stat in that case. The
      # existing host_service_authentication and proxy_enforcement
      # checks perform their own fetches because they need to inspect
      # specific error classes for gap vs warn semantics; they
      # intentionally re-issue the request rather than share state with
      # this helper.
      def readiness_payload
        @readiness_payload ||= fetch_readiness_payload
      end

      def fetch_readiness_payload
        return nil if host_url.blank? || host_token.blank?

        client = AppleVerification::HostClient.new(endpoint: host_url)
        client.call(version: AppleVerification::HostService::API_VERSION,
          operation: "readiness", payload: {}, token: host_token)
      rescue StandardError
        nil
      end

      def read_active_vm_count
        result = shell.run("tart", "list")
        return 0 unless result.success?

        result.stdout_lines.count { |line| line.start_with?("paid-vm") || line.include?("paid-vm") }
      end

      def find_matching_image(vm_names)
        vm_names.each do |name|
          computed = shell.vm_dir_digest(name)
          next if computed.nil?

          approved = approved_image_digests.find { |digest| digests_match?(digest, computed) }
          return { name:, approved:, computed: } if approved
        end
        nil
      end

      def digests_match?(approved, computed)
        normalize_digest(approved) == normalize_digest(computed)
      end

      def normalize_digest(digest)
        digest.to_s.delete_prefix("sha256:").downcase
      end

      def pass(id, detail)
        Result.new(id:, status: :pass, detail:, fix: nil)
      end

      def warn(id, detail)
        Result.new(id:, status: :warn, detail:, fix: nil)
      end

      def gap(id, detail, fix)
        Result.new(id:, status: :gap, detail:, fix:)
      end
    end
  end
end
