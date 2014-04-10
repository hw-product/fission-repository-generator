require 'tempfile'
require 'reaper'
require 'fission-repository-generator'

module Fission
  module RepositoryGenerator
    class Generator < Fission::Callback

      include Fission::Utils::Constants

      attr_reader :object_store, :pkg_store, :default_key_prefix, :pkg_key_prefix

      def setup(*args)
        @object_store = Fission::Assets::Store.new
        @default_key_prefix = Carnivore::Config.get(:fission, :repository_generator, :key_prefix) || 'repository-generator'
        if(creds = Carnivore::Config.get(:fission, :repository_generator, :package_assets, :assets_store, :credentials))
          if(Carnivore::Config.get(:fission, :repository_generator, :package_assets, :assets_store, :domain))
            creds = creds.merge(:path_style => true)
            creds.delete(:region)
            @pkg_key_prefix = nil
          else
            @pkg_key_prefix = default_key_prefix
          end
          @pkg_store = Fission::Assets::Store.new(creds.merge(:bucket => :none))
        else
          @pkg_key_prefix = default_key_prefix
          @pkg_store = object_store
        end
      end

      def valid?(message)
        super do |payload|
          retrieve(payload, :data, :package_builder, :categorized) ||
            retrieve(payload, :data, :package_builder, :package_list)
        end
      end

      def execute(message)
        failure_wrap(message) do |payload|
          init_payload(payload)
          config_path = fetch_repository_configuration(payload)
          list = Reaper::PackageList.new(config_path, {
              :package_root => 'packages',
              :package_bucket => retrieve(payload, :data, :account, :name)
            }.to_rash
          )
          [retrieve(payload, :data, :package_builder, :categorized),
            retrieve(payload, :data, :package_builder, :package_list)].compact.each do |pkgs|
            pkgs.each do |origin, codenames|
              codenames.each do |codename, packages|
                packages.each do |pkg|
                  list.options.merge!(
                    :origin => origin,
                    :codename => codename,
                    :component => !!PRERELEASE.detect{|string| pkg.include?(string)} ? 'prerelease' : 'stable'
                  )
                  package = object_store.get(pkg)
                  package.close
                  new_path = File.join(Carnivore::Config.get(:fission, :repository_generator, :working_directory) || '/tmp', File.basename(pkg))
                  FileUtils.mv(package.path, new_path)
                  Reaper::Signer.new(
                    :signing_key => Carnivore::Config.get(:fission, :repository_generator, :signing_key, :default),
                    :package_system => File.extname(new_path).sub('.', '')
                  ).sign(new_path)
                  list.add_package(new_path).each do |key_path|
                    key_path = File.join(*[compute_pkg_prefix(payload), key_path].compact)
                    pkg_store.put(File.join('repository', key_path), new_path)
                  end
                  File.delete(new_path)
                end
              end
            end
          end
          list.write!
          store_repository(payload, config_path)
          store_repository_configuration(payload, config_path)
          job_completed(:repository_generator, payload, message)
        end
      end

      def store_repository(payload, config_file)
        repo_config = MultiJson.load(File.read(config_file))
        repo_config.keys.each do |pkg_system|
          generator = Reaper::Generator.new({
              :package_system => pkg_system,
              :package_config => repo_config,
              :output_directory => File.join(repository_output_directory(payload), pkg_system),
              :signer => Reaper::Signer.new(
                :signing_key => Carnivore::Config.get(:fission, :repository_generator, :signing_key, :default),
                :package_system => pkg_system
              )
            }.to_rash
          ).generate!
          packed = Fission::Assets::Packer.pack(repository_output_directory(payload))
          repo_key = File.join(
            default_key_prefix,
            'repositories',
            retrieve(payload, :data, :account, :name).to_s,
            pkg_system,
            [Time.now.to_i.to_s, File.basename(packed)].join('-')
          )
          object_store.put(repo_key, packed)
          File.delete(packed)
          payload[:data][:repository_generator][:repositories][pkg_system] = repo_key
        end
      end

      def repository_output_directory(payload)
        path = File.join(
          Carnivore::Config.get(:fission, :repository_generator, :working_directory) || '/tmp',
          'generated-repositories',
          retrieve(payload, :data, :account, :name)
        )
        FileUtils.mkdir_p(File.dirname(path))
        path
      end

      def store_repository_configuration(payload, config_path)
        object_key = repository_json_key(payload)
        object_store.put(object_key, config_path)
        File.delete(config_path)
        payload[:data][:repository_generator][:repository_config] = object_key
        true
      end

      def init_payload(payload)
        payload[:data][:repository_generator] ||= {}
        payload[:data][:repository_generator].merge!(
          :repositories => {}
        )
      end

      def fetch_repository_configuration(payload)
        begin
          json = object_store.get(repository_json_key(payload))
        rescue => e
          warn "Failed to locate existing repository JSON file: #{e.class}: #{e}"
        end
        if(json)
          json.close
          json.path
        else
          tmp_file = Tempfile.new('repository')
          tmp_file.close
          path = tmp_file.path
          tmp_file.delete
          path
        end
      end

      def repository_json_key(payload)
        File.join(
          default_key_prefix,
          retrieve(payload, :data, :account, :name),
          'repository.json'
        )
      end

      def compute_pkg_prefix(payload)
        unless(pkg_key_prefix)
          pkg_store.bucket = [retrieve(payload, :data, :account, :name),
            Carnivore::Config.get(:fission, :repository_generator, :package_assets, :assets_store, :domain)].join('.')
          nil
        else
          pkg_key_prefix
        end
      end

    end
  end
end

Fission.register(:repository_generator, :generator, Fission::RepositoryGenerator::Generator)
