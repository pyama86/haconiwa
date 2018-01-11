module Haconiwa
  class Runner
  end

  class LinuxRunner < Runner
    def initialize(base)
      @base = base
      validate_ruid(base)
    end

    VALID_HOOKS = [
      :setup,
      :before_fork,
      :after_fork,
      :before_chroot,
      :after_chroot,
      :before_start_wait,
      :teardown_container,
      :teardown,
      :after_reload,
      :after_failure,
      :system_failure,
    ]

    LOCKFILE_DIR = "/var/lock"

    def waitall(&how_you_run)
      wrap_daemonize do |barn, n|
        invoke_general_hook(:setup, barn)
        pids = how_you_run.call(n)

        if n
          n.print pids.join(',')
          n.close
        end

        drop_suid_bit
        while res = ::Process.waitpid2(-1)
          pid, status = res[0], res[1]
          pids.delete(pid)
          if status.success?
            Logger.puts "One of supervisors finished: #{pid}, #{status.inspect}"
          else
            Logger.puts "One of supervisors has error: #{pid}, #{status.inspect}"
            barn.exit_status = status
            invoke_general_hook(:system_failure, barn)
          end
          break if pids.empty?
        end

        invoke_general_hook(:teardown, barn)
      end
    rescue HacoFatalError => ex
      @base.system_exception = ex
      invoke_general_hook(:system_failure, @base)
      raise ex
    rescue => e
      @base.system_exception = e
      invoke_general_hook(:system_failure, @base)
      Logger.exception(e)
    end

    def run(options, init_command)
      GC.disable # FIXME: temp, thread GC problem

      begin
        pid_file = Pidfile.create(@base.container_pid_file)
      rescue => e
        Logger.exception e
      end

      unless init_command.empty?
        @base.init_command = init_command
      end

      raise_container do |base|
        invoke_general_hook(:before_fork, base)

        init_pidns_fd = nil
        begin
          init_pidns_fd = File.open("/proc/1/ns/pid", 'r')
        rescue => e
          Logger.warning "Failed to open original PID namespace file. This restricts some features of Haconiwa"
        end if base.namespace.flag?(::Namespace::CLONE_NEWPID)

        jail_pid(base)
        # The pipe to set guid maps
        if base.namespace.use_guid_mapping?
          r,  w  = IO.pipe
          r2, w2 = IO.pipe
        end
        done, kick_ok = IO.pipe
        pid = Process.fork do
          invoke_general_hook(:after_fork, base)

          begin
            ::Procutil.mark_cloexec
            [r, w2].each {|io| io.close if io }
            done.close
            ::Procutil.setsid if base.daemon?

            if base.network.enabled?
              nw_handler = NetworkHandler::Bridge.new(base.network)
              begin
                nw_handler.generate
                base.namespace.enter "net", via: nw_handler.to_ns_file
              rescue => e
                Logger.exception(e)
              end
            end
            Logger.debug("before namespace file: #{base.filesystem.chroot} exists: #{File.exists?(base.filesystem.chroot)}")
            apply_namespace(base.namespace)
            Logger.debug("after namespace file: #{base.filesystem.chroot} exists: #{File.exists?(base.filesystem.chroot)}")

            Logger.debug("OK: apply_namespace")
            apply_filesystem(base)
            Logger.debug("OK: apply_filesystem")
            apply_rlimit(base.resource)
            Logger.debug("OK: apply_rlimit")
            apply_cgroup(base)
            Logger.debug("OK: apply_cgroup")
            apply_remount(base)
            Logger.debug("OK: apply_remount")
            ::Procutil.sethostname(base.name) if base.namespace.flag?(::Namespace::CLONE_NEWUTS)

            apply_user_namespace(base.namespace)
            if base.namespace.use_guid_mapping?
              # ping and pong between parent
              w.puts "unshared"
              w.close

              r2.read
              r2.close
              switch_current_namespace_root
            end
            Logger.debug("OK: apply_user_namespace")

            invoke_general_hook(:before_chroot, base)

            do_chroot(base)
            Logger.debug("OK: do_chroot")
            invoke_general_hook(:after_chroot, base)

            reopen_fds(base.command) if base.daemon?

            apply_capability(base.capabilities)
            Logger.debug("OK: apply_capability")
            apply_seccomp(base.seccomp)
            Logger.debug("OK: apply_seccomp")
            switch_guid(base.guid)
            Logger.debug("OK: switch_guid")
            kick_ok.puts "done"
            kick_ok.close
            Logger.debug("OK: kick parent process to resume")

            Logger.info "Container is going to exec: #{base.init_command.inspect}"
            Exec.execve(base.environ, *base.init_command)
          rescue => e
            Logger.exception(e)
            exit(127)
          end
        end
        ::Namespace.setns(::Namespace::CLONE_NEWPID, fd: init_pidns_fd.fileno) if init_pidns_fd
        base.pid = pid
        kick_ok.close

        if base.namespace.use_guid_mapping?
          Logger.info "Using gid/uid mapping in this container..."
          [w, r2].each {|io| io.close }
          r.read
          r.close
          set_guid_mapping(base.namespace, pid)
          Logger.info "Mapping setup is OK"

          w2.puts "mapped"
          w2.close
        end

        done.read # wait for container is done
        done.close
        persist_namespace(pid, base.namespace)

        base.created_at = Time.now
        base.supervisor_pid = ::Process.pid

        drop_suid_bit
        Logger.puts "Container fork success and going to wait: pid=#{pid}"
        base.waitloop.wait_interval = base.wait_interval
        base.waitloop.register_hooks(base)
        base.waitloop.register_sighandlers(base, self)
        base.waitloop.register_custom_sighandlers(base, base.signal_handler)

        invoke_general_hook(:before_start_wait, base)
        Logger.debug "WaitLoop instance status: #{base.waitloop.inspect}"

        pid, status = base.waitloop.run_and_wait(pid)
        base.exit_status = status
        invoke_general_hook(:teardown_container, base)
        unless status.success?
          invoke_general_hook(:after_failure, base)
        end

        cleanup_supervisor(base)
        if base.network.enabled?
          nw_handler = NetworkHandler::Bridge.new(base.network)
          begin
            nw_handler.cleanup
          rescue => e
            Logger.warning "Network cleanup failed: #{e.message}. Skip on quit"
          end
        end

        if status.success?
          Logger.puts "Container successfully exited: #{status.inspect}"
        else
          Logger.warning "Container failed: #{status.inspect}"
        end
        Logger.puts "Remoing pidfile: #{pid_file}"
        pid_file.remove # in any case
        Logger.puts "Removed pidfile: #{pid_file}"
      end
    end

    def attach(exe)
      base = @base
      if !base.pid
        begin
          ppid = ::Pidfile.pidof(base.container_pid_file)
          base.pid = ppid_to_pid(ppid)
        rescue => e
          Logger.exception "PID detecting failed: #{e.class}, #{e.message}. It seems you should specify container PID by -t option"
        end
      end

      if exe.empty?
        exe = "/bin/bash"
      end

      if base.namespace.use_pid_ns
        ::Namespace.setns(::Namespace::CLONE_NEWPID, pid: base.pid)
      end
      pid = Process.fork do
        if base.network.enabled?
          nw_handler = NetworkHandler::Bridge.new(base.network)
          base.namespace.enter "net", via: nw_handler.to_ns_file
        end
        flag = base.namespace.to_flag_without_pid_and_user
        ::Namespace.setns(flag, pid: base.pid)

        if base.namespace.to_flag & ::Namespace::CLONE_NEWUSER != 0
          ::Namespace.setns(::Namespace::CLONE_NEWUSER, pid: base.pid)
        end

        apply_cgroup(base)
        do_chroot(base)

        switch_current_namespace_root if base.namespace.use_guid_mapping?
        apply_capability(base.attached_capabilities)
        switch_guid(base.guid)

        Logger.info "Attach process is going to exec: #{base.init_command.inspect}"
        Exec.exec(*exe)
      end
      Logger.info "Attach process fork success: pid=#{pid}"

      pid, status = Process.waitpid2 pid
      if status.success?
        Logger.puts "Process successfully exited: #{status.inspect}"
      else
        Logger.warning "Process failed: #{status.inspect}"
      end
    end

    def reload(name, new_cg, new_cg2, new_resource, targets)
      if targets.include?(:cgroup)
        Logger.info "Reloading... :cgroup"
        reapply_cgroup(name, new_cg, new_cg2)
      end

      if targets.include?(:resource)
        Logger.info "Reloading... :resource"
        reapply_rlimit(@base.pid, new_resource)
      end

      invoke_general_hook(:after_reload, @base)
    end

    def kill(sigtype, timeout)
      if !@base.pid
        begin
          ppid = ::Pidfile.pidof(@base.container_pid_file)
          @base.pid = ppid_to_pid(ppid)
        rescue => e
          Logger.exception "PID detecting failed: #{e.class}, #{e.message}. It seems you should specify container PID by -t option"
        end
      end

      ::Process.kill sigtype.to_sym, @base.pid

      # timeout < 0 means "do not wait"
      if timeout < 0
        Logger.puts "Send signal success"
        return
      end

      (timeout * 10).times do
        usleep 1000
        unless ::Pidfile.locked?(@base.container_pid_file)
          Logger.puts "Kill success"
          return
        end
      end

      Logger.warning "Killing seemd to be failed in #{timeout} seconds. Check out process PID=#{@base.pid}"
      Process.exit 1
    end

    def cleanup_supervisor(base)
      recover_suid_bit do
        cleanup_cgroup(base)
        ::Pidfile.new(base.container_pid_file).unlock
      end
      base.cleaned = true
    end

    def validate_ruid(base)
      if base.rid_validator
        unless base.rid_validator.call(::Process::Sys.getuid, ::Process::Sys.getgid)
          raise "Invalid user/group to invoke suid-haconiwa: #{::Process::Sys.getuid}:#{::Process::Sys.getgid}"
        end
      end
    end

    private

    def ppid_to_pid(ppid)
      status = `find /proc -maxdepth 2 -regextype posix-basic -regex '/proc/[0-9]\\+/status'`.
               split.
               find {|f| File.read(f).include? "PPid:\t#{ppid}\n" rescue false }
      raise(HacoFatalError, "Container PID not found by find") unless status
      status.split('/')[2].to_i
    end

    def raise_container(&b)
      b.call(@base)
    end

    def wrap_daemonize(&b)
      if @base.daemon?
        r, w = IO.pipe
        ppid = Process.fork do
          l = nil
          begin
            l = ::Lockfile.lock(LOCKFILE_DIR + "/." + @base.project_name.to_s + ".hacolock")

            r.close
            ::Procutil.daemon_fd_reopen
            Logger.info "Daemonized..."
            Logger.info "Create lock: #{l.inspect}"
            b.call(@base, w)
          rescue => e
            Logger.exception(e)
          ensure
            if l
              l.unlock
              system "rm -f #{l.path}"
            end
          end
        end
        w.close
        _pids = r.read
        if _pids.empty?
          Logger.puts "Container cluster cannot be booted. Please check syslog"
        else
          Logger.puts "pids: #{_pids}"
          pids = _pids.split(',').map{|v| v.to_i }
          r.close

          Logger.puts "Container cluster successfully up. PID={supervisors: #{pids.inspect}, root: #{ppid}}"
        end
      else
        begin
          l = ::Lockfile.lock(LOCKFILE_DIR + "/." + @base.project_name.to_s + ".hacolock")
          Logger.puts "Create lock: #{l.inspect}"
          b.call(@base, nil)
        ensure
          if l
            l.unlock
            system "rm -f #{l.path}"
          end
        end
      end
    end

    def jail_pid(base)
      ret = if base.namespace.use_pid_ns
              ::Namespace.unshare(::Namespace::CLONE_NEWPID)
            elsif base.namespace.enter_existing_pidns?
              f = File.open(namespace.ns_to_path[::Namespace::CLONE_NEWPID])
              r = ::Namespace.setns(ns, fd: f.fileno)
              f.close
              r
            else
              0
            end
      if ret < 0
        Logger.exception "Unsharing or setting PID namespace failed"
      end
    end

    def invoke_general_hook(hookpoint, base)
      hook = base.general_hooks[hookpoint]
      hook.call(base) if hook
    rescue Exception => e
      Logger.warning("General container hook at #{hookpoint.inspect} failed. Skip")
      Logger.warning("#{e.class} - #{e.message}")
    end

    def apply_namespace(namespace)
      if ::Namespace.unshare(namespace.to_flag_for_unshare) < 0
        Logger.exception "Some namespace is unsupported by this kernel. Please check"
      end

      if namespace.setns_on_run?
        namespace.ns_to_path.each do |ns, path|
          next if ns == ::Namespace::CLONE_NEWPID
          next if ns == ::Namespace::CLONE_NEWUSER
          f = File.open(path)
          if ::Namespace.setns(ns, fd: f.fileno) < 0
            Logger.exception "Some namespace is unsupported by this kernel. Please check"
          end
          f.close
        end
      end
    end

    def apply_user_namespace(namespace)
      flg = namespace.to_flag & ::Namespace::CLONE_NEWUSER
      if flg != 0 and ::Namespace.unshare(flg) < 0
        raise "User namespace is unsupported by this kernel. Please check"
      end

      if path = namespace.ns_to_path[::Namespace::CLONE_NEWUSER]
        f = File.open(path)
        if ::Namespace.setns(::Namespace::CLONE_NEWUSER, fd: f.fileno) < 0
          raise "User namespace is unsupported by this kernel. Please check"
        end
        f.close
      end
    end

    def set_guid_mapping(namespace, pid)
      if m = namespace.uid_mapping
        File.open("/proc/#{pid}/uid_map", "w") do |map|
          map.write "#{m[:min].to_i} #{m[:offset].to_i} #{m[:max].to_i}"
        end
      end

      if m = namespace.gid_mapping
        File.open("/proc/#{pid}/gid_map", "w") do |map|
          map.write "#{m[:min].to_i} #{m[:offset].to_i} #{m[:max].to_i}"
        end
      end
    end

    def apply_filesystem(base)
      cwd = Dir.pwd
      Mount.make_private "/"
      owner_options = base.rootfs.to_owner_options
      base.filesystem.mount_points.each do |mp|
        Logger.debug("Mounting: #{mp.inspect}")
        case
        when mp.fs
          Mount.mount mp.normalized_src(cwd), mp.dest, owner_options.merge(mp.options).merge(type: mp.fs)
        else
          Mount.bind_mount mp.normalized_src(cwd), mp.dest, owner_options.merge(mp.options)
        end
      end
      base.network_mountpoint.each do |mp|
        Logger.debug("Mounting: #{mp.inspect}")
        unless File.exist? mp.dest
          File.open(mp.dest, "w+") {|f| f.print "" }
        end
        Mount.bind_mount mp.normalized_src(cwd), mp.dest, {readonly: true}.merge(owner_options)
      end
    end

    CG_MAPPING = {
      "cpu"     => Cgroup::CPU,
      "cpuset"  => Cgroup::CPUSET,
      "cpuacct" => Cgroup::CPUACCT,
      "blkio"   => Cgroup::BLKIO,
      "memory"  => Cgroup::MEMORY,
      "pids"    => Cgroup::PIDS,
    }
    def apply_cgroup(base)
      base.cgroup.controllers.each do |controller|
        Logger.debug "Creating cgroup controller #{controller}"
        Logger.exception("Invalid or unsupported controller name: #{controller}") unless CG_MAPPING.has_key?(controller)

        c = CG_MAPPING[controller].new(base.name)
        base.cgroup.groups_by_controller[controller].each do |pair|
          key, attr = pair
          value = base.cgroup[key]
          c.send "#{attr}=", value
        end
        c.create
        c.attach
      end

      unless base.cgroupv2.groups.empty?
        cg = ::CgroupV2.new_group(base.name)
        cg.create
        base.cgroupv2.groups.each do |key, value|
          cg[key.to_s] = value.to_s
        end
        cg.commit
        cg.attach
      end
    end

    def reapply_cgroup(name, cgroup, cgroupv2)
      if cgroup
        cgroup.controllers.each do |controller|
          Logger.debug "Modifying cgroup controller #{controller}"
          Logger.exception("Invalid or unsupported controller name: #{controller}") unless CG_MAPPING.has_key?(controller)
          cls = CG_MAPPING[controller]
          c = cls.new(name)
          cgroup.groups_by_controller[controller].each do |pair|
            key, attr = pair
            value = cgroup[key]
            c.send "#{attr}=", value
          end
          c.modify
        end
      end

      if cgroupv2 && !cgroupv2.groups.empty?
        cg = ::CgroupV2.new_group(name)
        cgroupv2.groups.each do |key, value|
          cg[key.to_s] = value.to_s
        end
        cg.commit
      end
    rescue Exception => e
      Logger.warning "Reapply failed: #{e.class}, #{e.message}"
      e.backtrace.each{|l| Logger.warning "    #{l}" }
    end

    def cleanup_cgroup(base)
      base.cgroup.controllers.each do |controller|
        Logger.exception("Invalid or unsupported controller name: #{controller}") unless CG_MAPPING.has_key?(controller)

        c = CG_MAPPING[controller].new(base.name)
        c.delete
      end
    end

    # TODO: check inheritable
    #       and handling when it is non-root
    def apply_capability(capabilities)
      if capabilities.acts_as_whitelist?
        ids = capabilities.whitelist_ids
        (0..38).each do |cap|
          break unless ::Capability.supported? cap
          next if ids.include?(cap)
          ::Capability.drop_bound cap
        end
      else
        capabilities.blacklist_ids.each do |cap|
          ::Capability.drop_bound cap
        end
      end
    rescue => e
      showid = capabilities.acts_as_whitelist? ? capabilities.whitelist_ids : capabilities.blacklist_ids
      Logger.exception "Maybe there are unsupported caps in #{showid.inspect}: #{e.class} - #{e.message}"
    end

    def apply_seccomp(seccomp)
      if seccomp.def_action
        ctx = ::Seccomp.new(default: seccomp.def_action)
        seccomp.defblock.call(ctx)
        ctx.load
      end
    end

    def apply_rlimit(rlimit)
      rlimit.limits.each do |limit|
        type = ::Resource.const_get("RLIMIT_#{limit[0]}")
        soft = [:unlimited, :infinity].include?(limit[1]) ? ::Resource::RLIM_INFINITY : limit[1]
        hard = [:unlimited, :infinity].include?(limit[2]) ? ::Resource::RLIM_INFINITY : limit[2]
        ::Resource.setrlimit(type, soft, hard)
      end
    end

    def reapply_rlimit(pid, rlimit)
      rlimit.limits.each do |limit|
        type = ::Resource.const_get("RLIMIT_#{limit[0]}")
        soft = [:unlimited, :infinity].include?(limit[1]) ? ::Resource::RLIM_INFINITY : limit[1]
        hard = [:unlimited, :infinity].include?(limit[2]) ? ::Resource::RLIM_INFINITY : limit[2]
        ::Resource.setprlimit(pid, type, soft, hard)
      end
    end

    def apply_remount(base)
      owner_options = base.rootfs.to_owner_options
      base.filesystem.independent_mount_points.each do |mp|
        opts = ["tmpfs", "devpts"].include?(mp.fs) ? {type: mp.fs}.merge(owner_options) : {type: mp.fs}
        Mount.mount mp.src, "#{base.filesystem.chroot}#{mp.dest}",opts
      end

      if base.lxcfs_root
        %w(
          /proc/cpuinfo
          /proc/diskstats
          /proc/meminfo
          /proc/stat
          /proc/swaps
          /proc/uptime
        ).each do |procfile|
          Mount.bind_mount "#{base.lxcfs_root}#{procfile}", "#{base.filesystem.chroot}#{procfile}", readonly: true
        end
      end
    end

    def reopen_fds(command)
      devnull = "/dev/null"
      inio  = command.stdin  || File.open(devnull, 'r')
      outio = command.stdout || File.open(devnull, 'a')
      errio = command.stderr || File.open(devnull, 'a')
      ::Procutil.fd_reopen3(inio.fileno, outio.fileno, errio.fileno)
    end

    def do_chroot(base)
      if base.filesystem.chroot
        Dir.chdir ExpandPath.expand([base.filesystem.chroot, base.workdir].join('/'))
        Dir.chroot base.filesystem.chroot
      else
        Dir.chdir base.workdir
      end
    end

    def switch_current_namespace_root
      ::Process::Sys.setgid(0)
      ::Process::Sys.setuid(0)
    end

    def switch_guid(guid)
      uid = guid.uid || ::Process::Sys.getuid
      gid = guid.gid || ::Process::Sys.getgid
      ::Process::Sys.setgid(gid)
      ::Process::Sys.__setgroups(guid.groups + [gid])
      ::Process::Sys.setuid(uid)
    end

    def drop_suid_bit
      if ::Process::Sys.getuid != ::Process::Sys.geteuid
        ::Process::Sys.seteuid(::Process::Sys.getuid)
      end

      if ::Process::Sys.getgid != ::Process::Sys.getegid
        ::Process::Sys.setegid(::Process::Sys.getgid)
      end
    end

    def recover_suid_bit(&b)
      ::Process::Sys.seteuid(0)
      b.call
    ensure
      ::Process::Sys.seteuid(::Process::Sys.getuid)
    end

    def persist_namespace(pid, namespace)
      namespace.namespaces.each do |flag, options|
        if path = options[:persist_in]
          ::Namespace.persist_ns pid, flag, path
          Logger.info "Namespace is persisted: #{path}"
        end
      end
    end

    def process_exists?(pid)
      ::Process.kill(0, pid)
    rescue RuntimeError
      false
    end

    def confirm_existence_pid_file(pid_file)
      if File.exist? pid_file
        if process_exists?(File.read(pid_file).to_i)
          raise "PID file #{pid_file} exists. You may be creating the container with existing name #{@base.name}!"
        else
          begin
            File.unlink(pid_file)
            Logger.debug("Since the process does not exist, delete the PID file #{pid_file}")
          rescue
            raise "Failed to delete PID file #{pid_file}."
          end
        end
      end
    end
  end
end
