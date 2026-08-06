require "solid_objects/doctor"

namespace :solid_objects do
  desc "Verify the Solid Objects installation"
  task doctor: :environment do
    report = SolidObjects::Doctor.new.call
    puts report
    abort "Solid Objects doctor failed" unless report.healthy?
  end
end
