require 'fission'
require 'fission-repository-generator/version'
require 'fission-repository-generator/generator'
require 'fission-repository-generator/formatter'

Fission.service(
  :repository_generator,
  :description => 'Generate repositories for publishing',
  :configuration => {
    :public => {
      :type => :boolean,
      :description => 'Generate for public publishing'
    }
  }
)
