$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__)) + '/lib/'
require 'fission-repository-generator/version'
Gem::Specification.new do |s|
  s.name = 'fission-repository-generator'
  s.version = Fission::RepositoryGenerator::VERSION.version
  s.summary = 'Fission Repository Generator'
  s.author = 'Heavywater'
  s.email = 'fission@hw-ops.com'
  s.homepage = 'http://github.com/heavywater/fission-repository-generator'
  s.description = 'Give packages a nice warm home'
  s.require_path = 'lib'
  s.add_dependency 'fission'
  s.add_dependency 'reaper'
  s.files = Dir['**/*']
end
