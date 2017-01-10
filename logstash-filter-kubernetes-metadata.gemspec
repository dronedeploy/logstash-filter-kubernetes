Gem::Specification.new do |s|
  s.name = 'logstash-filter-kubernetes-metadata'
  s.version = '0.1.6'
  s.licenses = ['Apache License (2.0)']
  s.require_paths = ["lib"]
  s.files = Dir['lib/**/*', 'spec/**/*', '*.gemspec', 'Gemfile']
  s.test_files = s.files.grep(%r{^(test|spec|features)/})
  s.summary = "kubernetes metadata"
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "filter" }
  s.authors = [ "bakins" ]
  s.add_runtime_dependency "logstash-core", ">= 2.0.0", "< 3.0.0"
  s.add_runtime_dependency 'rest-client', "~> 1.8.0"
  s.add_runtime_dependency 'lru_redux', "~> 1.1.0"
  s.add_development_dependency 'logstash-devutils'
  s.add_development_dependency 'sinatra'
  s.add_development_dependency 'webrick'
end
