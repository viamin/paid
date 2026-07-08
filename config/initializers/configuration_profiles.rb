# frozen_string_literal: true

# Built-in configuration profile postures are declared as plain Ruby data in
# {ConfigurationProfiles::Registry::PROFILES}, so no runtime registration is
# required. This initializer is intentionally minimal — it exists to make the
# "configuration_profiles" boundary easy to grep for and to leave room for
# future per-tenant dynamic registration without re-introducing a
# module/class mismatch with the {Registry} design.
