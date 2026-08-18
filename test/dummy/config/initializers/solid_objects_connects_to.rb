# frozen_string_literal: true

if ENV["SOLID_OBJECTS_DUMMY_CONNECTS_TO"]
  SolidObjects.configure do |config|
    config.connects_to = { database: { writing: :primary } }
  end
end
