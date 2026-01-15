class Macmic < Formula
  desc "The realtime mic monitor tool"
  homepage "https://github.com/haruaki-nayuta/MacMic"
  url "https://github.com/haruaki-nayuta/MacMic/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "66b1b6c0b45ed5c7f3e29c4d9c804f299640bc3cbfe69ad5072dfe0520a2874c"
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
