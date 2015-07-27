require 'tempfile'
require 'fission-repository-generator'

module Fission
  module RepositoryGenerator
    class Generator < Fission::Callback

      include Fission::Utils::Constants

      # If running within java, extract helper utility script from jar
      # ball and write to local system to allow shellout to work as expected.
      def setup(*_)
        require 'reaper-man'
        location = ReaperMan::Signer::HELPER_COMMAND
        if(location.include?('jar!'))
          tmp_file = Tempfile.new('reaper-man')
          new_location = File.join(Dir.home, File.basename(tmp_file.path))
          tmp_file.delete
          File.open(new_location, 'w') do |file|
            file.puts File.read(location)
          end
          File.chmod(0755, new_location)
          ReaperMan::Signer.send(:remove_const, :HELPER_COMMAND)
          ReaperMan::Signer.const_set(:HELPER_COMMAND, new_location)
          warn "Updated ReaperMan utility script location: #{new_location}"
        end
      end

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
          list = ReaperMan::PackageList.new(fetch_configuration(payload), Smash.new)

          payload.fetch(:data, :repository_generator, :add, Smash.new).each do |pkgs|
            pkgs.each do |origin, codenames|
              codenames.each do |codename, packages|
                packages_directory = File.join(working_directory(payload), 'packages', origin)
                FileUtils.mkdir_p(packages_directory)
                packages.each do |pkg|
                  debug "Processing file - Origin: #{origin} Codename: #{codename} Package: #{pkg}"
                  event!(:info, :info => "Processing file - Origin: #{origin} Codename: #{codename} Package: #{pkg}")
                  list.options.merge!(
                    :origin => origin,
                    :codename => codename,
                    :component => prerelease?(pkg) ? 'unstable' : 'stable'
                  )
                  package = asset_store.get(pkg)
                  pkg_path = File.join(packages_directory, File.basename(pkg))
                  FileUtils.mv(package.path, pkg_path)
                  if(config[:signing_key])
                    ReaperMan::Signer.new(
                      :signing_key => config[:signing_key],
                      :package_system => File.extname(pkg_path).sub('.', '')
                    ).package(pkg_path)
                    event!(:info, :info => "Signed package: #{pkg}")
                  end
                  list.add_package(pkg_path).each do |key_path|
                    payload.set(:data, :repository_generator, :package_assets, key_path, pkg)
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
        event!(:info, :info => 'Storing repository files to asset store')
        repo_config = MultiJson.load(File.read(config_file)).to_smash
        repo_config.keys.each do |pkg_system|
          generator = ReaperMan::Generator.new(
            Smash.new(
              :package_system => pkg_system,
              :package_config => repo_config,
              :output_directory => File.join(output_directory(payload), pkg_system),
              :signer => config[:signing_key] ? ReaperMan::Signer.new(
                :signing_key => config[:signing_key],
                :package_system => pkg_system
              ) : nil
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
        event!(:info, :info => 'Storing of repository assets complete')
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
          'generated-repositories'
        )
        FileUtils.mkdir_p(File.dirname(path))
        path
      end

      # Store repository configuration information to asset store
      #
      # @param payload [Smash]
      # @param config_path [String] path to config file
      # @return [TrueClass]
      def store_configuration(payload, config_path)
        object_key = json_key(payload)
        asset_store.put(object_key, File.open(config_path, 'r'))
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
          File.write(path, '{}')
        end
        path
      end

    end
  end
end

Fission.register(:repository_generator, :generator, Fission::RepositoryGenerator::Generator)
