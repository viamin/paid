# frozen_string_literal: true

module AppleVerification
  module Setup
    # Translates a preflight report into a numbered manual action plan. The
    # plan matches the canonical Markdown operator guide so no independently
    # maintained duplicate guide is introduced.
    # @spec APPLE-SETUP-005
    class Plan
      Action = Data.define(:id, :title, :commands, :proof, :guide_section)

      MANUAL_ACTIONS = {
        virtualization_permission: Action.new(
          id: :virtualization_permission,
          title: "Grant Apple virtualization permission",
          commands: [ "sysctl -n kern.hv_vmm_present" ],
          proof: "must print 1",
          guide_section: "Grant virtualization permission"
        ),
        tart_binary: Action.new(
          id: :tart_binary,
          title: "Install or upgrade Tart",
          commands: [ "brew install cirruslabs/cli/tart", "tart --version" ],
          proof: "must print major 2 or later",
          guide_section: "Install Tart and Softnet"
        ),
        softnet: Action.new(
          id: :softnet,
          title: "Start Softnet",
          commands: [ "sudo tart softnet start", "tart softnet status" ],
          proof: "must report running",
          guide_section: "Install Tart and Softnet"
        ),
        approved_image: Action.new(
          id: :approved_image,
          title: "Publish the approved immutable image",
          commands: [
            "tart clone <source-image> paid-macos-base",
            "bin/rails runner 'puts AppleVerificationImage.find_by(name: \"paid-macos-base\")&.digest'"
          ],
          proof: "must print sha256:<digest> matching the AppleWorkerProfile constraint",
          guide_section: "Create and publish the base image"
        ),
        xcode_toolchain: Action.new(
          id: :xcode_toolchain,
          title: "Install Xcode and accept the license",
          commands: [
            "sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer",
            "sudo xcodebuild -license accept",
            "xcodebuild -version"
          ],
          proof: "must print Xcode <version> <build>",
          guide_section: "Install Xcode and Simulator runtimes"
        ),
        simulator_runtimes: Action.new(
          id: :simulator_runtimes,
          title: "Install approved Simulator runtimes",
          commands: [ "xcodebuild -downloadPlatform iOS", "xcrun simctl list runtimes" ],
          proof: "must list the runtimes named in the worker profile",
          guide_section: "Install Xcode and Simulator runtimes"
        ),
        guest_gui_account: Action.new(
          id: :guest_gui_account,
          title: "Create the dedicated non-admin guest GUI account",
          commands: [
            "sudo sysadminctl -addUser paidguest -fullName 'Paid Verification' -UID 555 -GID 20 -shell /bin/zsh",
            "sudo dseditgroup -o edit -a paidguest -t user _developer",
            "sudo defaults write /Library/Preferences/com.apple.loginwindow DisableScreenLockOverride -bool YES"
          ],
          proof: "id paidguest must exist with no admin group and no iCloud-linked system account",
          guide_section: "Create the guest GUI account"
        ),
        host_service_authentication: Action.new(
          id: :host_service_authentication,
          title: "Register the trusted macOS host service",
          commands: [
            "sudo cp config/com.paid.macos-host.plist /Library/LaunchDaemons/",
            "sudo launchctl load /Library/LaunchDaemons/com.paid.macos-host.plist",
            "bin/paid host-service rotate-token > /etc/paid/host-token"
          ],
          proof: "APPLE_VERIFICATION_HOST_URL readiness probe returns cpu/memory/disk keys",
          guide_section: "Register the host service"
        ),
        proxy_enforcement: Action.new(
          id: :proxy_enforcement,
          title: "Wire the Paid-controlled egress proxy",
          commands: [ "bin/paid host-service set network.proxy-relay paid-egress" ],
          proof: "readiness payload must include network.proxy_relay=paid-egress",
          guide_section: "Configure proxy enforcement"
        ),
        capacity: Action.new(
          id: :capacity,
          title: "Recover host capacity",
          commands: [
            "df -g /",
            "bin/paid apple-worker reconcile --destroy-orphans",
            "vm_stat | awk '/free/ {print $3}'"
          ],
          proof: "must report ≥ 60 GiB free disk, ≤ 1 active Apple VM, and ≥ 25% free host memory",
          guide_section: "Cleanup and quarantine"
        )
      }.freeze

      GUIDE_PATH = "docs/rdrs/apple-worker-operator-guide.md"

      def self.call(...)
        new(...).call
      end

      def initialize(report)
        @report = report
      end

      def call
        gap_results.map.with_index(1) do |result, index|
          action = MANUAL_ACTIONS.fetch(result.id) do
            raise MissingActionError, "no manual action registered for preflight gap #{result.id}"
          end

          {
            index:,
            id: action.id,
            title: action.title,
            detail: result.detail,
            commands: action.commands,
            proof: action.proof,
            guide_section: action.guide_section
          }
        end
      end

      def to_markdown
        call.then { |actions| render(actions) }
      end

      class MissingActionError < StandardError; end

      private

      attr_reader :report

      def gap_results
        Array(report.respond_to?(:gap_results) ? report.gap_results : report[:gap_results])
      end

      def render(actions)
        return "All preflight checks passed; no manual actions required." if actions.empty?

        lines = [ "# Manual operator actions", "" ]
        actions.each do |action|
          lines << "## #{action[:index]}. #{action[:title]}"
          lines << ""
          lines << "Preflight observed: `#{action[:detail]}`."
          lines << ""
          lines << "Run these commands:"
          action[:commands].each do |command|
            lines << "```bash"
            lines << command
            lines << "```"
          end
          lines << ""
          lines << "Expected proof: #{action[:proof]}."
          lines << ""
          lines << "See `#{GUIDE_PATH}##{action[:guide_section]}` for full context."
          lines << ""
        end
        lines.join("\n")
      end
    end
  end
end
