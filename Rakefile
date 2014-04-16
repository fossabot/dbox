# encoding: utf-8

require 'rubygems'
require 'rake'

require 'jeweler'
Jeweler::Tasks.new do |gem|
  # gem is a Gem::Specification... see http://docs.rubygems.org/read/chapter/20 for more options
  gem.name = "dbox"
  gem.homepage = "http://github.com/kenpratt/dbox"
  gem.license = "MIT"
  gem.summary = "Dropbox made easy."
  gem.description = "An easy-to-use Dropbox client with fine-grained control over syncs. Think of it as halfway point between the developer API and a normal client, which gives you control over what and when Dropbox syncs but handles all the details."
  gem.email = "ken@kenpratt.net"
  gem.authors = ["Ken Pratt"]
  gem.executables = ["dbox"]
end
Jeweler::RubygemsDotOrgTasks.new

require 'rspec/core'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.pattern = FileList['spec/**/*_spec.rb']
end

RSpec::Core::RakeTask.new(:rcov) do |spec|
  spec.pattern = 'spec/**/*_spec.rb'
  spec.rcov = true
end

task :default => :spec
