require 'tempfile'
require 'reaper-man'
require 'fission-repository-generator'

module Fission
  module RepositoryGenerator
    class Generator < Fission::Callback

      include Fission::Utils::Constants

      # Message validity
      #
      # @param message [Carnivore::Message]
      # @return [Truthy, Falsey]
      def valid?(message)
        super do |payload|
          payload.get(:data, :repository_generator, :add) ||
            payload.get(:data, :repository_generator, :remove)
        end
      end

      # Generate and store repository
      #
      # @param message [Carnivore::Message]
      def execute(message)
        failure_wrap(message) do |payload|
          payload.set(:data, :repository_generator, :modifications,
            Smash.new(:added => [], :removed => [])
          )
          list = ReaperMan::PackageList.new(fetch_configuration(payload), Smash.new)

          payload.fetch(:data, :repository_generator, :add, Smash.new).each do |pkgs|
            pkgs.each do |origin, codenames|
              codenames.each do |codename, packages|
                packages_directory = File.join(working_directory(payload), 'packages', origin)
                FileUtils.mkdir_p(packages_directory)
                packages.each do |pkg|
                  list.options.merge!(
                    :origin => origin,
                    :codename => codename,
                    :component => prerelease?(pkg) ? 'unstable' : 'stable'
                  )
                  package = asset_store.get(pkg)
                  pkg_path = File.join(packages_directory, File.basename(pkg))
                  FileUtils.mv(package.path, pkg_path)
                  # TODO:::
                  # Need to add config option with key name which we
                  # will fetch from asset store. This will allow users
                  # to provide keys via web ui, then reference them
                  # in custom config and we can get proper dynamic
                  # access from here.
                  # ReaperMan::Signer.new(
                  #   :signing_key => config[:signing_key],
                  #   :package_system => File.extname(pkg_path).sub('.', '')
                  # ).sign(pkg_path)
                  list.add_package(pkg_path).each do |key_path|
                    payload.set(:data, :repository_generator, :package_assets,
                      File.join('packages', origin, File.basename(pkg)), pkg)
                  end
                  package.close
                  File.delete(pkg_path)
                end
              end
            end
          end
          list.write!
          store_repository(payload, list.path)
          store_configuration(payload, list.path)
          FileUtils.rm_rf(working_directory(payload))
          job_completed(:repository_generator, payload, message)
        end
      end

      # Store the generated repository into the remote asset store
      #
      # @param payload [Smash]
      # @param config_file [String] path to packages config file
      # @return [TrueClass]
      def store_repository(payload, config_file)
        repo_config = MultiJson.load(File.read(config_file)).to_smash
        repo_config.keys.each do |pkg_system|
          generator = ReaperMan::Generator.new(
            Smash.new(
              :package_system => pkg_system,
              :package_config => repo_config,
              :output_directory => File.join(output_directory(payload), pkg_system)
              # :signer => ReaperMan::Signer.new(
              #   :signing_key => Carnivore::Config.get(:fission, :repository_generator, :signing_key, :default),
              #   :package_system => pkg_system
              # )
            )
          ).generate!
          packed = asset_store.pack(output_directory(payload))
          repo_key = File.join(
            'repositories',
            payload.fetch(:data, :account, :name, 'default'),
            pkg_system,
            [Time.now.to_i.to_s, File.basename(packed)].join('-')
          )
          asset_store.put(repo_key, packed)
          File.delete(packed)
          payload.set(:data, :repository_generator, :generated, pkg_system, repo_key)
        end
        true
      end

      # Generate the repository config file key to be used in
      # asset store
      #
      # @param payload [Smash]
      # @return [String]
      def json_key(payload)
        File.join(
          'repositories',
          payload.fetch(:data, :account, :name, 'default'),
          'repository.json'
        )
      end

      # Create output directory for repository generation
      #
      # @param payload [Smash]
      # @return [String] path
      def output_directory(payload)
        path = File.join(
          working_directory(payload),
          'generated-repositories',
          Celluloid.uuid
        )
        FileUtils.mkdir_p(File.dirname(path))
        path
      end

      # Generate temporary working directory
      #
      # @param payload [Smash]
      # @return [String] path
      def working_directory(payload)
        path = File.join(
          config.fetch(:working_directory, '/tmp/fission-repositories'),
          payload[:message_id]
        )
        FileUtils.mkdir_p(path)
        path
      end

      # Store repository configuration information to asset store
      #
      # @param payload [Smash]
      # @param config_path [String] path to config file
      # @return [TrueClass]
      def store_configuration(payload, config_path)
        object_key = json_key(payload)
        asset_store.put(object_key, config_path)
        File.delete(config_path)
        payload.set(:data, :repository_generator, :config, object_key)
        true
      end

      # Fetch repository configuration file from asset store
      #
      # @param payload [Smash]
      # @return [String] path
      def fetch_configuration(payload)
        begin
          json = asset_store.get(json_key(payload))
        rescue => e
          warn "Failed to locate existing repository JSON file: #{e.class}: #{e}"
        end
        path = File.join(
          working_directory(payload),
          'repository.json'
        )
        if(json)
          FileUtils.mv(json.path, path)
        else
          File.write('{}', path)
        end
        path
      end

    end
  end
end

Fission.register(:repository_generator, :generator, Fission::RepositoryGenerator::Generator)
