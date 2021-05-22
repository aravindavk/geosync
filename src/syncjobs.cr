require "./config"

struct JobSummary
  property entries_count : Int32 = 0,
    elapsed_time_seconds : Float64 = 0,
    bytes_synced : UInt64 = 0
end

struct Job
  property proc : Process,
    stdout : IO::Memory,
    stderr : IO::Memory

  def initialize(@proc, @stdout, @stderr)
  end
end

# ```
# confmgr = ConfigManager.new("sample_config.yaml")
# syncjobs = SyncJobs.new(confmgr)
# crawl(confmgr.config.crawl_dir) do |batch|
#   batch.files.each do |f|
#     syncjobs.add(f)
#   end
#   syncjobs.sync
#   puts syncjobs.summary
#
#   # If any hardlinks available then sync it
#   if batch.hardlinks.size > 0
#     batch.hardlinks.each do |_, hls|
#       syncjobs.add(hls)
#     end
#     syncjobs.sync
#     puts syncjobs.summary
#   end
# end
# ```
class SyncJobs
  def initialize(@confmgr : ConfigManager)
    @jobs = [] of Array(String)
    @summary = [] of JobSummary

    (0...@confmgr.config.syncjobs).each do |idx|
      @jobs << [] of String
      @summary << JobSummary.new
    end

    @current_job = 0
  end

  # Add one entry to a Rsync job then switch to
  # next job
  def add(entry : String)
    @jobs[@current_job] << entry

    next_job
  end

  # Add all entries to single Rsync Job
  # Very useful for syncing Hardlinks
  # To use `-H` or preserve hardlinks options with rsync,
  # all hardlinks should be synced in the same process.
  def add(entries : Array(String))
    @jobs[@current_job].concat(entries)

    next_job
  end

  # Cycle the Rsync Jobs so that files will be distributed uniformly
  private def next_job
    if @current_job < (@confmgr.config.syncjobs - 1)
      @current_job += 1
    else
      @current_job = 0
    end
  end

  def rsync_ssh_opts
    "ssh -oControlMaster=auto -S #{@confmgr.config.ssh_ctrl_path} -p #{@confmgr.config.ssh_port}"
  end

  def rsync_job
    cmd = "rsync"
    args = [
      "-0",                       # Use \x00 delimiter for the files list
      "--stats",                  # Include rsync stats
      "--files-from=-",           # Files from Stdin
      "--delete-missing-args",    # If file deleted in Primary, then try to delete in Target
      "--ignore-missing-args",    # If file is already deleted in Secondary then don't worry
      "-H",                       # Preserve Hardlinks
      "-e", rsync_ssh_opts,       # SSH Control Master and Port options
      @confmgr.config.source_dir, # Source Path
      @confmgr.config.target,     # Target Path (HOST:PATH format)
    ]
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    proc = Process.new(cmd, args: args, output: stdout, error: stderr, input: Process::Redirect::Pipe)

    Job.new(proc, stdout, stderr)
  end

  def speed(total_bytes, elapsed_time)
    speed = total_bytes/elapsed_time
    if speed > 1024*1024*1024
      "#{speed/(1024*1024*1024)} GiB/sec"
    elsif speed > 1024*1024
      "#{speed/(1024*1024)} MiB/sec"
    elsif speed > 1024
      "#{speed/1024} KiB/sec"
    else
      "#{speed} bytes/sec"
    end
  end

  # Start N rsync jobs and add the files to each
  # jobs stdin. Once all the jobs are started, wait for
  # the completion and then return response.
  def sync
    t1 = Time.monotonic
    reset_summary

    jobs = [] of Job
    start_times = [] of Time::Span
    (0...@confmgr.config.syncjobs).each do |idx|
      start_times << Time.monotonic
      proc = rsync_job
      proc.proc.input.write(@jobs[idx].join("\x00").to_slice)
      jobs << proc
    end

    total_bytes_synced : UInt64 = 0
    (0...@confmgr.config.syncjobs).each do |idx|
      stats = JobSummary.new
      stats.entries_count = @jobs[idx].size

      status = jobs[idx].proc.wait
      stats.elapsed_time_seconds = (Time.monotonic - start_times[idx]).total_seconds
      if status.success?
        jobs[idx].stdout.to_s.split("\n").each do |line|
          if line.starts_with?("Total transferred file size")
            stats.bytes_synced = line.split(":")[1].gsub(" bytes", "").gsub(",", "").strip.to_u64
            total_bytes_synced += stats.bytes_synced
          end
        end
        # TODO: How to parse stdout
        puts "Synced from Job #{idx} #{speed(stats.bytes_synced, stats.elapsed_time_seconds)}"
      else
        # TODO: How to get stderr string
        puts "Failed Sync #{@jobs[idx]} #{status.exit_code}"
      end

      @summary[idx] = stats
      @jobs[idx] = [] of String
    end

    elapsed_time = (Time.monotonic - t1).total_seconds
    puts "Total Elapsed Time: #{elapsed_time}"
    puts "Total Bytes Synced: #{total_bytes_synced}"
    puts "Speed: #{speed(total_bytes_synced, elapsed_time)}"
  end

  private def reset_summary
    (0...@confmgr.config.syncjobs).each do |idx|
      @summary[idx] = JobSummary.new
    end
  end

  def summary
    # Time it took for syncing(induvidual time and aggregated time)
    # Number of entries in each job
    # Size stats
    # Note: This summary will be reset when sync is called next time
    @summary
  end
end
