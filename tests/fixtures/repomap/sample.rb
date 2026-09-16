module Repo
  class Scanner
    def initialize(root)
      @root = root
    end

    def scan
      collect_files
    end
  end
end
