# frozen_string_literal: true

# Trusted, read-only, allowlisted post-deploy measurements against live
# tenant data. See docs/intent/post-deploy-measurement.
# @spec POST-DEPLOY-CHECK-001
module PostDeployChecks
  class UnknownCheckError < StandardError; end
  class AuthorizationError < StandardError; end
end
