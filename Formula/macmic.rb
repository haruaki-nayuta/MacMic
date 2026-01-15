class Macmic < Formula
  desc "The realtime mic monitor tool"
  homepage "https://github.com/haruaki-nayuta/MacMic"
  url "https://github.com/haruaki-nayuta/MacMic/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "eb173f73a43469f2fc33a710527cd8719639e9010d7e63b575288c4b3d07fa52"
  license "MIT"

  depends_on :xcode => ["12.0", :build]

  def install
    system "swiftc", "macmic.swift", "-o", "macmic"
    bin.install "macmic"
  end

  test do
    system "#{bin}/macmic", "-v"
  end
end
