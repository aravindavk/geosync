require "kemal"

require "./syncjobs"
require "./config"
require "./crawler"

module GeoSync
  @@confmgr = ConfigManager.new(ARGV[0])
  @@syncjobs = SyncJobs.new(@@confmgr)
  @@current_syncjobs_count = 0

  # Persistent SSH Connection to the node specified
  # SSH ControlMaster is used so all the other connections
  # will use this socket to improve the connection speed while syncing.
  def self.start_control_master
    # Start SSH Control Master
    cmd = "ssh"
    args = [
      "-p", "#{@@confmgr.config.ssh_port}",
      "-M",
      "-S", @@confmgr.config.ssh_ctrl_path,
      @@confmgr.config.target_node,
      "tail", "-f", "/dev/null",
    ]
    proc = Process.new(cmd, args: args)
    Log.info { "Connected to @@confmgr.config.target_node" }
    spawn do
      status = proc.wait
      if !status.success?
        Log.info { "Disconnected from #{@@confmgr.config.target_node}, Exiting.." }
        exit(1)
      end
    end
  end

  # TODO: Status implementation
  get "/status" do
    "Status"
  end

  get "/config" do
    @@confmgr.config.to_json
  end

  post "/reload" do
    @@confmgr.reload
  end

  def self.refresh_syncjobs
    if @@current_syncjobs_count != @@confmgr.config.syncjobs
      @@syncjobs = SyncJobs.new(@@confmgr)
      @@current_syncjobs_count = @@confmgr.config.syncjobs
    end
  end

  def self.fs_crawl
    crawl(@@confmgr.config.crawl_dir) do |batch|
      batch.files.each do |f|
        @@syncjobs.add(f)
      end
      @@syncjobs.sync
      puts @@syncjobs.summary

      # If any hardlinks available then sync it
      if batch.hardlinks.size > 0
        batch.hardlinks.each do |_, hls|
          @@syncjobs.add(hls)
        end
        @@syncjobs.sync
        puts @@syncjobs.summary
      end
    end
  end

  # TODO: Record stime and use that as start time
  def self.start
    start_control_master

    @@current_syncjobs_count = @@confmgr.config.syncjobs

    spawn do
      # Initial one time Filesystem Crawl
      # TODO: Run only when Historical Changelogs are not
      # available or config.syncmode = "crawl"
      fs_crawl

      # TODO: Implement Historical Changelogs based change detection

      loop do
        refresh_syncjobs

        if @@confmgr.config.syncmode == "crawl"
          fs_crawl
        end

        # TODO: Implement Changelog based change detection

        sleep 5.seconds
      end
    end

    # Start a ReST endpoint
    Kemal.run
  end
end

GeoSync.start
