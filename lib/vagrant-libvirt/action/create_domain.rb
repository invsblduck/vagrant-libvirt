require 'log4r'

module VagrantPlugins
  module ProviderLibvirt
    module Action
      class CreateDomain
        include VagrantPlugins::ProviderLibvirt::Util::ErbTemplate

        def initialize(app, env)
          @logger = Log4r::Logger.new('vagrant_libvirt::action::create_domain')
          @app = app
        end

        def _disk_name(name, disk)
          "#{name}-#{disk[:device]}.#{disk[:type]}"	# disk name
        end

        def _disks_print(disks)
          disks.collect do |x|
            "#{x[:device]}(#{x[:type]},#{x[:size]})"
          end.join(', ')
        end

        def _cdroms_print(cdroms)
          cdroms.collect { |x| x[:dev] }.join(', ')
        end

        def call(env)
          # Get config.
          config = env[:machine].provider_config

          # Gather some info about domain
          @name = env[:domain_name]
          @cpus = config.cpus.to_i
          @cpu_mode = config.cpu_mode
          @machine_type = config.machine_type
          @machine_arch = config.machine_arch
          @disk_bus = config.disk_bus
          @nested = config.nested
          @memory_size = config.memory.to_i * 1024
          @domain_volume_cache = config.volume_cache
          @kernel = config.kernel
          @cmd_line = config.cmd_line
          @initrd = config.initrd
          @graphics_type = config.graphics_type
          @graphics_autoport = config.graphics_autoport
          @graphics_port = config.graphics_port
          @graphics_ip = config.graphics_ip
          @graphics_passwd =  if config.graphics_passwd.to_s.empty?
                                ''
                              else
                                "passwd='#{config.graphics_passwd.to_s}'"
                              end
          @video_type = config.video_type
          @video_vram = config.video_vram
          @keymap = config.keymap
          
          # Boot order
          @boot_order = config.boot_order

          # Storage
          @storage_pool_name = config.storage_pool_name
          @disks = config.disks
          @cdroms = config.cdroms

          config = env[:machine].provider_config
          @domain_type = config.driver

          @os_type = 'hvm'

          # Get path to domain image from the storage pool selected.
          actual_volumes = env[:libvirt_compute].volumes.all.select do |x|
            x.pool_name == @storage_pool_name
          end
          domain_volume = ProviderLibvirt::Util::Collection.find_matching(
            actual_volumes,"#{@name}.img")
          raise Errors::DomainVolumeExists if domain_volume.nil?
          @domain_volume_path = domain_volume.path

          # the default storage prefix is typically: /var/lib/libvirt/images/
          storage_prefix = File.dirname(@domain_volume_path) + '/'	# steal

          @disks.each do |disk|
            disk[:path] ||= _disk_name(@name, disk)

            # On volume creation, the <path> element inside <target>
            # is oddly ignored; instead the path is taken from the
            # <name> element:
            # http://www.redhat.com/archives/libvir-list/2008-August/msg00329.html
            disk[:name] = disk[:path]

            disk[:absolute_path] = storage_prefix + disk[:path]

            if env[:libvirt_compute].volumes.select {
                |x| x.name == disk[:name] and x.pool_name == @storage_pool_name}.empty?
              # make the disk. equivalent to:
              # qemu-img create -f qcow2 <path> 5g
              begin
                env[:libvirt_compute].volumes.create(
                  name: disk[:name],
                  format_type: disk[:type],
                  path: disk[:absolute_path],
                  capacity: disk[:size],
                  #:allocation => ?,
                  pool_name: @storage_pool_name)
              rescue Fog::Errors::Error => e
                raise Errors::FogDomainVolumeCreateError,
                    error_message:  e.message
              end
            else
              disk[:preexisting] = true
            end
          end

          # Output the settings we're going to use to the user
          env[:ui].info(I18n.t('vagrant_libvirt.creating_domain'))
          env[:ui].info(" -- Name:              #{@name}")
          env[:ui].info(" -- Domain type:       #{@domain_type}")
          env[:ui].info(" -- Cpus:              #{@cpus}")
          env[:ui].info(" -- Memory:            #{@memory_size / 1024}M")
          env[:ui].info(" -- Base box:          #{env[:machine].box.name}")
          env[:ui].info(" -- Storage pool:      #{@storage_pool_name}")
          env[:ui].info(" -- Image:             #{@domain_volume_path}")
          env[:ui].info(" -- Volume Cache:      #{@domain_volume_cache}")
          env[:ui].info(" -- Kernel:            #{@kernel}")
          env[:ui].info(" -- Initrd:            #{@initrd}")
          env[:ui].info(" -- Graphics Type:     #{@graphics_type}")
          env[:ui].info(" -- Graphics Port:     #{@graphics_port}")
          env[:ui].info(" -- Graphics IP:       #{@graphics_ip}")
          env[:ui].info(" -- Graphics Password: #{@graphics_passwd.empty? ? 'Not defined' : 'Defined'}")
          env[:ui].info(" -- Video Type:        #{@video_type}")
          env[:ui].info(" -- Video VRAM:        #{@video_vram}")
          env[:ui].info(" -- Keymap:            #{@keymap}")
          
          @boot_order.each do |device|
            env[:ui].info(" -- Boot device:        #{device}")
          end

          if @disks.length > 0
            env[:ui].info(" -- Disks:         #{_disks_print(@disks)}")
          end

          @disks.each do |disk|
            msg = " -- Disk(#{disk[:device]}):     #{disk[:absolute_path]}"
            msg += " (shared. Remove only manualy)" if disk[:allow_existing]
            msg += " Not created - using existed." if disk[:preexisting]
            env[:ui].info(msg)
          end

          if @cdroms.length > 0
            env[:ui].info(" -- CDROMS:            #{_cdroms_print(@cdroms)}")
          end

          @cdroms.each do |cdrom|
            env[:ui].info(" -- CDROM(#{cdrom[:dev]}):        #{cdrom[:path]}")
          end

          env[:ui].info(" -- Command line : #{@cmd_line}")

          # Create libvirt domain.
          # Is there a way to tell fog to create new domain with already
          # existing volume? Use domain creation from template..
          begin
            server = env[:libvirt_compute].servers.create(
              xml: to_xml('domain'))
          rescue Fog::Errors::Error => e
            raise Errors::FogCreateServerError, error_message:  e.message
          end

          # Immediately save the ID since it is created at this point.
          env[:machine].id = server.id

          @app.call(env)
        end
      end
    end
  end
end
