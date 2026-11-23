# For trying it out (redmine/seed.sh, after the sample data): the module "Full-text search" on in every project, and the
# roles allowed to use it and to search external sources. Without these, only the global search would work, and an
# external source made with manifoldcf/add-folder.sh would find nothing until an administrator set them by hand.
Project.find_each do |project|
  project.enabled_module_names = (project.enabled_module_names + ['solr_search']).uniq
  project.save!
end
Role.givable.where(builtin: 0).each {|role| role.add_permission!(:use_solr_search, :search_external_sources) }
puts "Full-text search: on in #{Project.count} projects; roles allowed: #{Role.givable.where(builtin: 0).map(&:name).join(', ')}"
