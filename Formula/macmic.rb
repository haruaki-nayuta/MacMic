class Macmic < Formula
  desc "The realtime mic monitor tool"
  homepage "https://github.com/haruaki-nayuta/MacMic"
  url "https://github.com/haruaki-nayuta/MacMic/archive/refs/tags/v1.0.2.tar.gz"
  sha256 "fc483c486ac8f28970bc44c6e0dbf56cd825191a885257ff936164feef509d24"
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
