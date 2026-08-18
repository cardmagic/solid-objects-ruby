# frozen_string_literal: true

Rails.application.config.active_record.encryption.primary_key =
  "solid-objects-dummy-primary-key"
Rails.application.config.active_record.encryption.deterministic_key =
  "solid-objects-dummy-deterministic-key"
Rails.application.config.active_record.encryption.key_derivation_salt =
  "solid-objects-dummy-key-derivation-salt"
