struct FilesBatch
  property files = [] of String,
    hardlinks = Hash(UInt64, Array(String)).new,
    stime_update_dirs = [] of String,
    files_count = 0,
    batch_size = 0

  def initialize(@batch_size)
  end

  # Batch is full or not depending on the Batch Size
  # ```
  # batch = FilesBatch.new(2)
  # batch.files << "file1"
  # batch.files << "file2"
  # puts batch.full? # Returns true
  # ```
  def full?
    return false if @batch_size == 0

    @files_count >= @batch_size
  end
end

# Non-recursive file system Walk
# Yields list of files once the batch is full
# TODO: Implement depth first so that stime
# can be updated after completing one directory.
# TODO: Batch size will not apply to hardlinks.
# ```
# crawl("/bricks/gvol1/brick1/brick", 8000) do |batch|
#   # sync files
#   puts batch.files
#
#   # sync hardlinks
#   if batch.hardlinks.size > 0
#     puts batch.hardlinks
#   end
# end
# ```
def crawl(dirpath, batch_size = 8000)
  directories = [] of Path
  directories << Path.new(dirpath)
  dirs_count = directories.size
  crawled_dirs_count = 0
  files_crawled = 0

  # Hardlinks are captured seperately and sent as
  # part of last Yield. If the Volume is with large
  # number of hardlinks, then it is not batched properly.
  hardlinks = Hash(UInt64, Array(String)).new

  batch = FilesBatch.new(batch_size)

  loop do
    # All the directories scanned are crawled or ignored
    break if dirs_count == crawled_dirs_count

    current_dir = directories[crawled_dirs_count]

    # TODO: Include more dirs to skip/ignore from config
    if current_dir.to_s.ends_with?("/.glusterfs")
      crawled_dirs_count += 1
      next
    end

    Dir.entries(current_dir).each do |entry|
      next if entry == "." || entry == ".."

      full_path = Path[current_dir].join(entry)

      # If directory then add to the directory queue
      if File.directory?(full_path)
        directories << full_path
        dirs_count += 1
      else
        info = File.info(full_path)
        # All files in GlusterFS Volume will have link count 2
        # if any user created hardlinks exist then do not include
        # in general batch, send them together at once. These
        # hardlinks will be synced with `--preserve-hardlinks` flag
        if info.@stat.st_nlink > 2
          if !hardlinks[info.@stat.st_ino]?
            hardlinks[info.@stat.st_ino] = [] of String
          end
          hardlinks[info.@stat.st_ino] << full_path.relative_to(dirpath).to_s
        else
          # If it is not hardlink then Yield the batch only
          # if it is full, else continue collecting file paths
          batch.files << full_path.relative_to(dirpath).to_s
          batch.files_count += 1
          if batch.full?
            yield batch
            # Reset the batch for next iteration
            batch = FilesBatch.new(batch_size)
          end
        end
      end
    end

    crawled_dirs_count += 1
  end

  # Add hardlinks to the batch if any
  batch.hardlinks = hardlinks

  yield batch if batch.files_count > 0 || batch.hardlinks.size > 0
end
