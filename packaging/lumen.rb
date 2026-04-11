require "language/node"

class Lumen < Formula
  desc "Lumen - macOS game streaming server (fork of Sunshine)"
  homepage "https://github.com/saxlamen/Lumen"
  url "https://github.com/saxlamen/Lumen.git", branch: "main"
  license "GPL-3.0-only"
  version "1.0.0"

  depends_on "cmake" => :build
  depends_on "node" => :build
  depends_on "pkgconf" => :build
  depends_on "boost"
  depends_on "curl"
  depends_on "icu4c@78"
  depends_on "miniupnpc"
  depends_on "openssl@3"
  depends_on "opus"
  depends_on "llvm" => :build

  fails_with :clang do
    build 1400
    cause "Requires C++23 support"
  end

  def setup_build_environment
    ENV["LUMEN_BUILD"] = "true"
  end

  def base_cmake_args
    %W[
      -DBUILD_WERROR=ON
      -DCMAKE_CXX_STANDARD=23
      -DCMAKE_INSTALL_PREFIX=#{prefix}
      -DHOMEBREW_ALLOW_FETCHCONTENT=ON
      -DOPENSSL_ROOT_DIR=#{Formula["openssl"].opt_prefix}
      -DSUNSHINE_ASSETS_DIR=lumen/assets
      -DSUNSHINE_BUILD_HOMEBREW=ON
    ]
  end

  def build_cmake_args
    args = base_cmake_args
    args << "-DBUILD_TESTS=OFF"
    args << "-DBUILD_DOCS=OFF"
    args << "-DBOOST_USE_STATIC=OFF"
    args
  end

  def build_and_install_project
    system "cmake", "-S", ".", "-B", "build", "-G", "Unix Makefiles",
            *std_cmake_args,
            *build_cmake_args

    system "make", "-C", "build"
    system "make", "-C", "build", "install"
  end

  def install
    setup_build_environment
    build_and_install_project
  end

  service do
    run [opt_bin/"sunshine", "#{ENV["HOME"]}/.config/sunshine/sunshine.conf"]
  end

  def caveats
    <<~EOS
      Thanks for installing Lumen!

      Binary name: sunshine (upstream convention)
      Config dir: ~/.config/sunshine/

      To start manually:
        sunshine ~/.config/sunshine/sunshine.conf

      Or use Homebrew services:
        brew services start lumen
    EOS
  end

  test do
    system bin/"sunshine", "--version"
  end
end
