# -*- mode: ruby; tab-width: 4; indent-tabs-mode: t -*-
require 'pathname'
require 'date'
require 'open3'

# ssh remote session support
require 'net-ssh-open3'

# Get ZFS object.
def ZFS(path, *param)
	return path if path.is_a? ZFS

    if param.size > 0
	  param = param.first
	else
	  param = nil
	end

	path = Pathname(path).cleanpath.to_s

	if path.match(/^\//)
		ZFS.mounts[path]
	elsif path.match('@')
		ZFS::Snapshot.new(path, param)
	else
		ZFS::Filesystem.new(path, param)
	end
end

class String
  def to_boolean
	self.match(/(true|t|yes|y|1)$/i) != nil
  end
end

# Pathname-inspired class to handle ZFS filesystems/snapshots/volumes
class ZFS
	@zfs_path   = "zfs"
	@zpool_path = "zpool"
	
	# session for "stdin, stdout, stderr" 
    # can be local or remote via ssh
	attr_accessor :session
	@session = Open3

	attr_reader :name
	attr_reader :pool
	attr_reader :path

	class NotFound < Exception; end
	class AlreadyExists < Exception; end
	class InvalidName < Exception; end

	# Create a new ZFS object (_not_ filesystem).
	def initialize(name, session=nil)
	    if session
		  @session = self.class.make_ssh_session(session) 
		else
		  @session = Open3
		end
		@name, @pool, @path = name, *name.split('/', 2)
	end
		  
	# If @session is a Open3 session the ZFS Filesystem is assumed to
	# be local
	def is_local
	  return @session.class != Net::SSH::Connection::Session
	end

	# If @session is of type Net::SSH the ZFS Filesystem is assumed to
	# be on a remote machine
	def is_remote
	  return @session.class == Net::SSH::Connection::Session
	end

	# Return the parent of the current filesystem, or nil if there is none.
	def parent
		p = Pathname(name).parent.to_s
		if p == '.'
			nil
		else
			ZFS(p, @session)
		end
	end

	# Returns the children of this filesystem
	def children(opts={})
		raise NotFound if !exist?

		cmd = [ZFS.zfs_path].flatten + %w(list -H -r -oname -tfilesystem)
		cmd << '-d1' unless opts[:recursive]
		cmd << name

		stdout, stderr, status = @session.capture3(*cmd)
		if status.success? and stderr == ""
			childs = stdout.lines.drop(1).collect do |filesystem|
				ZFS(filesystem.chomp, @session)
			end
		    return childs
		else
			raise Exception, "something went wrong"
		end
	end

	# Does the filesystem exist?
	def exist?
		cmd = [ZFS.zfs_path].flatten + %w(list -H -oname) + [name]

		out, status = @session.capture2e(*cmd)
		if status.success? and out == "#{name}\n"
			true
		else
			false
		end
	end

	# Create filesystem
	def create(opts={})
		return nil if exist?

		cmd = [ZFS.zfs_path].flatten + ['create']
		cmd << '-p' if opts[:parents]
		cmd += ['-V', opts[:volume]] if opts[:volume]
		cmd << name

		out, status = @session.capture2e(*cmd)
		if status.success? and out.empty?
			return self
		elsif out.match(/dataset already exists\n$/)
			nil
		else
			raise Exception, "something went wrong: #{out}, #{status}"
		end
	end

	# Destroy filesystem
	def destroy!(opts={})
		raise NotFound if !exist?

		cmd = [ZFS.zfs_path].flatten + ['destroy']
		cmd << '-r' if opts[:children]
		cmd << name

		out, status = @session.capture2e(*cmd)

		if status.success? and out.empty?
			return true
		else
			raise Exception, "something went wrong"
		end
	end

	# Stringify
	def to_s
		"#<ZFS:#{name}>"
	end

	# ZFS's are considered equal if they are the same class and name
	def ==(other)
		other.class == self.class && other.name == self.name
	end

	def [](key)
		cmd = [ZFS.zfs_path].flatten + %w(get -ovalue -Hp) + [key.to_s, name]

		stdout, stderr, status = @session.capture3(*cmd)

		if status.success? and stderr.empty? and stdout.lines.count == 1
		    return stdout.chomp
		else
		    raise Exception, "something went wrong.\nstderr: %s\nstdout: %s\nstatus: %s" % [stderr.chomp, stdout.chomp, status.to_s]
		end
	end

	def []=(key, value)
		cmd = [ZFS.zfs_path].flatten + ['set', "#{key.to_s}=#{value}", name]

		out, status = @session.capture2e(*cmd)

		if status.success? and out.empty?
			return value
		else
			raise Exception, "something went wrong"
		end
	end

	class << self
		attr_accessor :zfs_path
		attr_accessor :zpool_path
		attr_accessor :session

	     def make_ssh_session(config)
		   if config.is_a? Hash
			 @session = Net::SSH.start(config[:host], config[:user], :password => config[:password])
		   else
			 @session = config
		   end
		   return @session
		 end

		# Get an Array of all pools
		def pools(session=nil)
		    if session
			  make_ssh_session(session)
			end

			cmd = [ZFS.zpool_path].flatten + %w(list -Honame)

			stdout, stderr, status = @session.capture3(*cmd)

			if status.success? and stderr.empty?
				stdout.lines.collect do |pool|
					ZFS(pool.chomp, session)
				end
			else
				raise Exception, "something went wrong"
			end
		end

		# Get a Hash of all mountpoints and their filesystems
		def mounts(session=nil)
		    if session
			  make_ssh_session(session)
			end

			cmd = [ZFS.zfs_path].flatten + %w(get -rHp -oname,value mountpoint)

			stdout, stderr, status = @session.capture3(*cmd)

			if status.success? and stderr.empty?
				mounts = stdout.lines.collect do |line|
					fs, path = line.chomp.split(/\t/, 2)
					[path, ZFS(fs, session)]
				end
				Hash[mounts]
			else
				raise Exception, "something went wrong"
			end
		end

		# Define an attribute
		def property(name, opts={})

			case opts[:type]
			when :size, :integer
				# FIXME: also takes :values. if :values is all-Integers, these are the only options. if there are non-ints, then :values is a supplement

				define_method name do
					Integer(self[name])
				end
				define_method "#{name}=" do |value|
					self[name] = value.to_s
				end if opts[:edit]

			when :boolean
				# FIXME: booleans can take extra values, so there are on/true, off/false, plus what amounts to an enum
				# FIXME: if options[:values] is defined, also create a 'name' method, since 'name?' might not ring true
				# FIXME: replace '_' by '-' in opts[:values]
				define_method "#{name}?" do
					self[name] == 'on'
				end
				define_method "#{name}=" do |value|
					self[name] = value ? 'on' : 'off'
				end if opts[:edit]

			when :enum
				define_method name do
					sym = (self[name] || "").gsub('-', '_').to_sym
					if opts[:values].grep(sym)
						return sym
					else
						raise "#{name} has value #{sym}, which is not in enum-list"
					end
				end
				define_method "#{name}=" do |value|
					self[name] = value.to_s.gsub('_', '-')
				end if opts[:edit]

			when :snapshot
				define_method name do
					val = self[name]
					if val.nil? or val == '-'
						nil
					else
						ZFS(val, @session)
					end
				end

			when :float
				define_method name do
					Float(self[name])
				end
				define_method "#{name}=" do |value|
					self[name] = value
				end if opts[:edit]

			when :string
				define_method name do
					self[name]
				end
				define_method "#{name}=" do |value|
					self[name] = value
				end if opts[:edit]

			when :date
				define_method name do
					DateTime.strptime(self[name], '%s')
				end

			when :pathname
				define_method name do
					Pathname(self[name])
				end
				define_method "#{name}=" do |value|
					self[name] = value.to_s
				end if opts[:edit]

			else
				puts "Unknown type '#{opts[:type]}'"
			end
		end
		private :property
	end

	property :available,            type: :size
	property :compressratio,        type: :float
	property :creation,             type: :date
	property :defer_destroy,        type: :boolean
	property :mounted,              type: :boolean
	property :origin,               type: :snapshot
	property :refcompressratio,     type: :float
	property :referenced,           type: :size
	property :type,                 type: :enum, values: [:filesystem, :snapshot, :volume]
	property :used,                 type: :size
	property :usedbychildren,       type: :size
	property :usedbydataset,        type: :size
	property :usedbyrefreservation, type: :size
	property :usedbysnapshots,      type: :size
	property :userrefs,             type: :integer

	property :aclinherit,           type: :enum,    edit: true, inherit: true, values: [:discard, :noallow, :restricted, :passthrough, :passthrough_x]
	property :atime,                type: :boolean, edit: true, inherit: true
	property :canmount,             type: :boolean, edit: true,                values: [:noauto]
	property :checksum,             type: :boolean, edit: true, inherit: true, values: [:fletcher2, :fletcher4, :sha256]
	property :compression,          type: :boolean, edit: true, inherit: true, values: [:lzjb, :gzip, :gzip_1, :gzip_2, :gzip_3, :gzip_4, :gzip_5, :gzip_6, :gzip_7, :gzip_8, :gzip_9, :zle]
	property :copies,               type: :integer, edit: true, inherit: true, values: [1, 2, 3]
	property :dedup,                type: :boolean, edit: true, inherit: true, values: [:verify, :sha256, 'sha256,verify']
	property :devices,              type: :boolean, edit: true, inherit: true
	property :exec,                 type: :boolean, edit: true, inherit: true
	property :logbias,              type: :enum,    edit: true, inherit: true, values: [:latency, :throughput]
	property :mlslabel,             type: :string,  edit: true, inherit: true
	property :mountpoint,           type: :pathname,edit: true, inherit: true
	property :nbmand,               type: :boolean, edit: true, inherit: true
	property :primarycache,         type: :enum,    edit: true, inherit: true, values: [:all, :none, :metadata]
	property :quota,                type: :size,    edit: true,                values: [:none]
	property :readonly,             type: :boolean, edit: true, inherit: true
	property :recordsize,           type: :integer, edit: true, inherit: true, values: [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072]
	property :refquota,             type: :size,    edit: true,                values: [:none]
	property :refreservation,       type: :size,    edit: true,                values: [:none]
	property :reservation,          type: :size,    edit: true,                values: [:none]
	property :secondarycache,       type: :enum,    edit: true, inherit: true, values: [:all, :none, :metadata]
	property :setuid,               type: :boolean, edit: true, inherit: true
	property :sharenfs,             type: :boolean, edit: true, inherit: true # FIXME: also takes 'share(1M) options'
	property :sharesmb,             type: :boolean, edit: true, inherit: true # FIXME: also takes 'sharemgr(1M) options'
	property :snapdir,              type: :enum,    edit: true, inherit: true, values: [:hidden, :visible]
	property :sync,                 type: :enum,    edit: true, inherit: true, values: [:standard, :always, :disabled]
	property :version,              type: :integer, edit: true,                values: [1, 2, 3, 4, :current]
	property :vscan,                type: :boolean, edit: true, inherit: true
	property :xattr,                type: :boolean, edit: true, inherit: true
	property :zoned,                type: :boolean, edit: true, inherit: true
	property :jailed,               type: :boolean, edit: true, inherit: true
	property :volsize,              type: :size,    edit: true

	property :casesensitivity,      type: :enum,    create_only: true, values: [:sensitive, :insensitive, :mixed]
	property :normalization,        type: :enum,    create_only: true, values: [:none, :formC, :formD, :formKC, :formKD]
	property :utf8only,             type: :boolean, create_only: true
	property :volblocksize,         type: :integer, create_only: true, values: [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072]
end


class ZFS::Snapshot < ZFS
	# Return sub-filesystem
	def +(path)
		raise InvalidName if path.match(/@/)

		parent + path + name.sub(/^.+@/, '@')
	end

	# Just remove the snapshot-name
	def parent
		ZFS(name.sub(/@.+/, ''), @session)
	end

	# Rename snapshot
	def rename!(newname, opts={})
		raise AlreadyExists if (parent + "@#{newname}").exist?

		newname = (parent + "@#{newname}").name

		cmd = [ZFS.zfs_path].flatten + ['rename']
		cmd << '-r' if opts[:children]
		cmd << name
		cmd << newname

		out, status = @session.capture2e(*cmd)

		if status.success? and out.empty?
			initialize(newname)
			return self
		else
			raise Exception, "something went wrong"
		end
	end

	# Clone snapshot
	def clone!(clone, opts={})
		clone = clone.name if clone.is_a? ZFS

		raise AlreadyExists if ZFS(clone, @session).exist?

		cmd = [ZFS.zfs_path].flatten + ['clone']
		cmd << '-p' if opts[:parents]
		cmd << name
		cmd << clone

		out, status = @session.capture2e(*cmd)

		if status.success? and out.empty?
			return ZFS(clone, @session)
		else
			raise Exception, "something went wrong"
		end
	end

	# Send snapshot to another filesystem
	def send_to(dest, opts={})
		incr_snap = nil
		dest = ZFS(dest)

		if opts[:incremental] and opts[:intermediary]
			raise ArgumentError, "can't specify both :incremental and :intermediary"
		end

		incr_snap = opts[:incremental] || opts[:intermediary]
		if incr_snap
			if incr_snap.is_a? String and incr_snap.match(/^@/)
				incr_snap = self.parent + incr_snap
			else
				incr_snap = ZFS(incr_snap, @session)
				raise ArgumentError, "incremental snapshot must be in the same filesystem as #{self}" if incr_snap.parent != self.parent
			end

			snapname = incr_snap.name.sub(/^.+@/, '@')

			raise NotFound, "snapshot #{snapname} must exist at #{self.parent}" if self.parent.snapshots.grep(incr_snap).empty?
		    unless opts[:dry_run]
			  raise NotFound, "destination must already exist when receiving incremental stream" unless dest.exist?
			  raise NotFound, "snapshot #{snapname} must exist at #{dest}" if dest.snapshots.grep(dest + snapname).empty?
			end
		elsif (opts[:use_sent_name] || opts[:use_last_element_name])
			raise NotFound, "destination must already exist when using sent name" unless dest.exist?
		elsif dest.exist?
			#raise AlreadyExists, "destination must not exist when receiving full stream"
		end

	    # determine belonging session
		if dest.is_a? ZFS
		  dest_session = dest.session
		else
		  dest_session = @session
		end

		dest_name = dest.name if dest.is_a? ZFS
		incr_snap = incr_snap.name if incr_snap.is_a? ZFS

	    # collecting all options for "zfs send"
		send_opts = [ZFS.zfs_path].flatten + ['send']
	    send_opts << '-nv' if opts[:dry_run]
		send_opts << '-p'  if opts[:dataset_properties]
		send_opts.concat ['-i', incr_snap] if opts[:incremental]
		send_opts.concat ['-I', incr_snap] if opts[:intermediary]
		send_opts << '-R' if opts[:replication]
		send_opts << name
	    # if :transfer_mechanism_send is set append it using a pipe
	    if (not opts[:dry_run]) && opts[:transfer_meachanism_send]
		  send_opts << "|"
		  if dest.is_remote
			send_opts << opts[:transfer_meachanism_send].gsub("<dest>", dest_session.host)
		  else
			send_opts << opts[:transfer_meachanism_send]
		  end
		end

	  # collecting all options for "zfs receive"
	    receive_opts = []
	    # if :transfer_mechanism_receive is set prefix it using a pipe
    	if (not opts[:dry_run]) && opts[:transfer_meachanism_receive]
		  if dest.is_remote
			receive_opts = [  opts[:transfer_meachanism_receive] % dest_session.host, "|" ]
		  else
			receive_opts = [  opts[:transfer_meachanism_receive],  "|" ]
		  end
		  receive_opts << ZFS.zfs_path
		  receive_opts << 'receive'
		else
		  receive_opts = [ZFS.zfs_path].flatten + ['receive']
		end
	    receive_opts << '-F' if	opts[:force_rollback]
	    receive_opts << '-e' if	opts[:use_last_element_name]
		receive_opts << '-d' if opts[:use_sent_name]
		receive_opts << '-v'
		receive_opts << dest_name

        if opts[:dry_run]
		  # dryrun mode
		  out, status = @session.capture2e(*send_opts)

		  raise Exception, "something went wrong" unless status.success? 
		  my_size_string = out.split("\n").grep(/total estimated/).first.split.last + "ibyte"
		  if my_size_string.to_f > 0 
			return my_size_string, "0 byte/s"
		  else
			return "0 byte", "0 byte/s"
		  end
		else
		  # actual sending the snapshot
		  if (!opts[:transfer_meachanism_send].nil?) ^ (!opts[:transfer_meachanism_receive].nil?) # xor
			raise Exception, "You have to specifiy both transfer mechanisms (:transfer_meachanism_send, :transfer_meachanism_receive)!"
		  end

		  # build send and receiving options
		  my_send_opts = send_opts.join(" ")
		  my_receive_opts = receive_opts.join(" ")

		  # init states
		  my_send_err = ""
		  my_receive_err = ""
		  my_receive_stdout = ""

		  if opts[:transfer_meachanism_send] && opts[:transfer_meachanism_receive]
			r_stdout = ""
			r_status = ""
			
			# starting receiving cmd
			receiving_thread = Thread.new { my_receive_stdout, my_receive_err, r_status = dest_session.capture3(my_receive_opts) }
			sleep 2 # saefty time margin to settle the receiving cmd

			# starting sending cmd
			stdout, my_send_err, status = @session.capture3(my_send_opts)

			# waiting for receiving cmd to finish
			receiving_thread.join
          else
			dest_session.popen3(my_receive_opts) do |rstdin, rstdout, rstderr, rthr|
			  rstdin.sync = true
			  @session.popen3(my_send_opts) do |sstdin, sstdout, sstderr, sthr|
			    sstdout.sync = true
				while !sstdout.eof?
				    rstdin.write(sstdout.read(128*1024))
				end
				raise "stink" unless sstderr.read == ''
			   end
			   my_send_err       = sstderr.read
			   my_receive_err    = rstderr.read
   			   my_receive_stdout = rstdout.read
		    end
		  end
		  
		  # Error handling
		  if my_send_err.size > 0 || my_receive_err.size > 0
			str_send_cmd    = "zfs send cmd: %s" % my_send_opts
			str_receive_cmd = "zfs receive cmd: %s" % my_receive_opts
			str_send_err    = "send stderr: %s" % my_send_err
			str_receive_err = "send stderr: %s" % my_receive_err
			raise Exception, "Something went wrong while sending a snapshot:\n%s\n%s\n%s\n%s" % [ str_send_cmd, str_send_err, str_receive_cmd, str_receive_err ]
		  end

		  # calculate some metrics and return
		  my_size_match  = my_receive_stdout.split("\n").grep(/^received/).first.match(/^received(.*)stream.*\((.*\/sec)\)/)
		  transfer_size  = my_size_match[1].strip.gsub(/([a-z])B$/i,'\1ibyte')
		  transfer_speed = my_size_match[2].strip.gsub(/([a-z])B\/sec/i,"\1ibyte/s")
 		  return transfer_size, transfer_speed
		end

	end
end


class ZFS::Filesystem < ZFS
	# Return sub-filesystem.
	def +(path)
		if path.match(/^@/)
			ZFS("#{name.to_s}#{path}", @session)
		else
			path = Pathname(name) + path
			ZFS(path.cleanpath.to_s, @session)
		end
	end

	# Rename filesystem.
	def rename!(newname, opts={})
		raise AlreadyExists if ZFS(newname, @session).exist?

		cmd = [ZFS.zfs_path].flatten + ['rename']
		cmd << '-p' if opts[:parents]
		cmd << name
		cmd << newname

		out, status = @session.capture2e(*cmd)

		if status.success? and out.empty?
			initialize(newname)
			return self
		else
			raise Exception, "something went wrong"
		end
	end

	# Create a snapshot.
	def snapshot(snapname, opts={})
		raise NotFound, "no such filesystem" if !exist?
		raise AlreadyExists, "#{snapname} exists" if ZFS("#{name}@#{snapname}", @session).exist?

		cmd = [ZFS.zfs_path].flatten + ['snapshot']
		cmd << '-r' if opts[:children]
		cmd << "#{name}@#{snapname}"

		out, status = @session.capture2e(*cmd)

		if status.success? and out.empty?
			return ZFS("#{name}@#{snapname}", @session)
		else
			raise Exception, "something went wrong"
		end
	end

	# Get an Array of all snapshots on this filesystem.
	def snapshots
		raise NotFound, "no such filesystem" if !exist?

		stdout, stderr = [], []
		cmd = [ZFS.zfs_path].flatten + %w(list -H -d1 -r -oname -tsnapshot) + [name]

		stdout, stderr, status = @session.capture3(*cmd)

		if status.success? and stderr.empty?
			stdout.lines.collect do |snap|
				ZFS(snap.chomp, @session)
			end
		else
			raise Exception, "something went wrong"
		end
	end

	# Promote this filesystem.
	def promote!
		raise NotFound, "filesystem is not a clone" if self.origin.nil?

		cmd = [ZFS.zfs_path].flatten + ['promote', name]

		out, status = @session.capture2e(*cmd)

		if status.success? and out.empty?
			return self
		else
			raise Exception, "something went wrong"
		end
	end
end
