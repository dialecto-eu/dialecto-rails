require "digest"
require "find"
require_relative "git"

module DialectoRails
  module Scan
    # The `Git` reading interface over a plain folder: for `scan --worktree` (a testing escape hatch that sends
    # what is on disk, not what is committed), and for sparse, blobless clones (the corpus), where `git
    # cat-file` would fetch every missing blob from the network. Blob ids are git's, so the scan checksum still
    # follows the bytes.
    class Worktree
      Entry = Git::Entry
      SKIPPED = %w[.git node_modules].freeze

      def initialize(root)
        @root = root
        @paths = {}
      end

      def entries(_sha = nil)
        found = []
        Find.find(@root) do |path|
          if SKIPPED.include?(File.basename(path)) then Find.prune
          elsif File.file?(path) && !File.symlink?(path)
            size = File.size(path)
            found << Entry.new(path: path.delete_prefix("#{@root}/"), blob: path, size: size)
          end
        end
        found.sort_by(&:path)
      end

      # The id is the file's path here; `blob_id` gives git's id for the bytes, for the checksum.
      def blob(id) = File.binread(id)

      def blob_id(id)
        bytes = File.binread(id)
        Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes)
      end
    end
  end
end
