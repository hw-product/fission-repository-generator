require 'fission-repository-generator'

module Fission
  module RepositoryGenerator
    module Formatters

      # Format payload for publisher
      class Publisher < Fission::Formatter

        SOURCE = :repository_generator
        DESTINATION = :repository_publisher

        # Format payload and add information for publisher
        #
        # @param payload [Smash]
        def format(payload)
          if(payload.get(:data, :repository_generator, :generated))
            payload.set(:data, :repository_publisher, :repositories,
              payload.get(:data, :repository_generator, :generated)
            )
          end
          if(payload.get(:data, :repository_generator, :package_assets))
            payload.set(:data, :repository_publisher, :package_assets,
              payload.get(:data, :repository_generator, :package_assets)
            )
          end
          payload.set(:data, :repository_publisher, :public, config[:public])
        end

      end

    end
  end
end
