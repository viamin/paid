# frozen_string_literal: true

# Solid Cable 4.1 batches broadcasts through a Rails executor worker. During a
# development reload, waiting for that worker under the unload lock deadlocks.
require Rails.root.join("lib/solid_cable/reload_safe_shutdown")
