require File.expand_path("../Abstract/portable-formula", __dir__)

# on macOS, Ruby builds require a BASERUBY already available on the system with
# the same version. I wasn't able to get the Homebrew formula for ruby working
# for this case, so we are stuck relying on ruby/setup-ruby for now.  If you're
# trying to build outside GHA, you probably need to set HOMEBREW_BASERUBY to the
# absolute path of a ruby binary for this to work.
#
# Ruby 2.7 differences from the 3.x abstracts:
# - No YJIT at all; the without-yjit option is kept (inert for codegen) so the
#   release build matrix works unchanged; it still selects the glibc@2.17
#   toolchain on Linux.
# - ext/openssl cannot build against OpenSSL 3.x, so this depends on
#   portable-openssl@1.1.1w instead.
# - No msgpack/bootsnap bundled-gem injection: 2.7's bundled-gems machinery
#   (gems/bundled_gems format, extract-gems destination, rbinstall) predates
#   the 3.x behavior the injection relies on, and never built gem extensions.
# - configure has no --enable-libedit=DIR; ext/readline wants the boolean
#   --enable-libedit plus --with-libedit-dir=PREFIX (mkmf dir_config).
class JdxRuby27 < Formula
  def self.inherited(subclass)
    subclass.class_eval do
      super

      desc "Powerful, clean, object-oriented scripting language"
      homepage "https://www.ruby-lang.org/"
      license "Ruby"

      # Match Ruby 2.7.x versions
      livecheck do
        formula "ruby"
        regex(/href=.*?ruby[._-]v?(2\.7\.\d+)\.t/i)
      end

      keg_only "portable formulae are keg-only"

      option "without-yjit", "Build Ruby without YJIT (required for glibc < 2.35)"

      depends_on "pkgconf" => :build
      depends_on "portable-libyaml@0.2.5" => :build
      depends_on "portable-openssl@1.1.1w" => :build

      on_linux do
        depends_on "portable-libedit" => :build
        depends_on "portable-libffi@3.5.1" => :build
        depends_on "portable-libxcrypt@4.4.38" => :build
        depends_on "portable-zlib@1.3.1" => :build

        if build.without? "yjit"
          depends_on "glibc@2.17" => :build
          depends_on "linux-headers@4.4" => :build
        end
      end

      prepend PortableFormulaMixin
    end
  end

 def install
    dep_names = deps.map(&:name)
    libyaml = Formula[dep_names.find{|d| d.start_with?("portable-libyaml") }]
    openssl = Formula[dep_names.find{|d| d.start_with?("portable-openssl") }]

    # Keep the shipped gperf output newer than its source: regenerating
    # props.h with gperf >= 3.1 yields size_t prototypes that conflict with
    # 2.7's unsigned int declaration and fail the build under modern gcc.
    system "touch", "enc/jis/props.h"

    # Ruby's configure supports --with-rdoc=ri,html; request only RI data to
    # keep portable packages smaller than a full HTML documentation install.
    # dbm/gdbm (stdlib until 3.0) are excluded: their extconfs link whatever
    # libgdbm is lying around (e.g. the Homebrew bottle installed as a helper
    # dep), which fails the portable linkage check.
    args = %W[
      --prefix=#{prefix}
      --enable-load-relative
      --with-out-ext=win32,win32ole,dbm,gdbm
      --without-gmp
      --with-rdoc=ri
      --disable-dependency-tracking
    ]

    # Correct MJIT_CC to not use superenv shim
    args << "MJIT_CC=/usr/bin/#{DevelopmentTools.default_compiler}"

    if ENV.key?("HOMEBREW_BASERUBY")
      baseruby = ENV["HOMEBREW_BASERUBY"]
      if !File.exist?(baseruby)
        odie "HOMEBREW_BASERUBY must contain the path to a ruby #{version} executable"
      end

      baseruby_version = baseruby && %x[#{baseruby} -v]
      if baseruby_version =~ /#{Regexp.escape(version)}/
        args += %W[--with-baseruby=#{baseruby}]
      else
        odie "HOMEBREW_BASERUBY must contain the path to a ruby #{version} executable, " \
          "but instead contains #{baseruby}, with version #{baseruby_version}"
      end
    end

    # We don't specify OpenSSL as we want it to use the pkg-config, which `--with-openssl-dir` will disable
    args += %W[
      --with-libyaml-dir=#{libyaml.opt_prefix}
    ]

    if OS.mac?
      args += %W[--enable-libedit]
    end

    if OS.linux?
      libffi = Formula[dep_names.find{|d| d.start_with?("portable-libffi") }]
      libxcrypt = Formula[dep_names.find{|d| d.start_with?("portable-libxcrypt") }]
      zlib = Formula[dep_names.find{|d| d.start_with?("portable-zlib") }]
      libedit = Formula[dep_names.find{|d| d.start_with?("portable-libedit") }]

      ENV["XCFLAGS"] = "-I#{libxcrypt.opt_include}"
      ENV["XLDFLAGS"] = "-L#{libxcrypt.opt_lib}"

      args += %W[
        --enable-libedit
        --with-libedit-dir=#{libedit.opt_prefix}
        --with-libffi-dir=#{libffi.opt_prefix}
        --with-zlib-dir=#{zlib.opt_prefix}
      ]

      # Ensure compatibility with older Ubuntu when built with Ubuntu 22.04
      args << "MKDIR_P=/bin/mkdir -p"

      # Don't make libruby link to zlib as it means all extensions will require it
      # It's also not used with the older glibc we use anyway
      args << "ac_cv_lib_z_uncompress=no"
    end

    # Append flags rather than override
    ENV["cflags"] = ENV.delete("CFLAGS")
    ENV["cppflags"] = ENV.delete("CPPFLAGS")
    ENV["cxxflags"] = ENV.delete("CXXFLAGS")

    system "./configure", *args
    # No `make extract-gems` here: 2.7's target runs via RUNRUBY (./miniruby,
    # which does not exist before `make`), and 2.7's rbinstall installs bundled
    # gems from gems/*.gem directly, so extraction is unnecessary.
    system "make"

    # Add a helper load path file so bundled gems can be easily used (used by brew's standalone/init.rb)
    # 2.7 extracts bundled gems into gems/ rather than .bundle/, so the globs
    # below are typically empty; the file is kept for interface parity.
    # 2.7's Makefile has no ruby.pc alias target; pkgconfig-data builds ruby-2.7.pc
    system "make", "pkgconfig-data"
    arch = Utils.safe_popen_read("pkg-config", "--variable=arch", "./ruby-#{version.major_minor}.pc").chomp
    mkdir_p "lib/#{arch}"
    File.open("lib/#{arch}/portable_ruby_gems.rb", "w") do |file|
      (Dir["extensions/*/*/*", base: ".bundle"] + Dir["gems/*/lib", base: ".bundle"]).each do |require_path|
        file.write <<~RUBY
          $:.unshift "\#{RbConfig::CONFIG["rubylibprefix"]}/gems/\#{RbConfig::CONFIG["ruby_version"]}/#{require_path}"
        RUBY
      end
    end

    system "make", "install"

    # Patch shell polyglot executables for RubyGems overwrite detection
    # RubyGems' check_executable_overwrite looks for "This file was generated by RubyGems"
    # after the Ruby shebang, but in shell polyglot format the comment is at the top.
    # This causes gem upgrades to fail with "conflicts with installed executable" errors.
    # See: https://github.com/jdx/mise/discussions/7268
    ohai "Patching shell polyglot executables in #{bin}"
    patched_count = 0
    Dir.glob("#{bin}/*").each do |exe|
      next unless File.file?(exe)
      content = File.read(exe)
      next unless content.start_with?("#!/bin/sh") && content.include?("#!/usr/bin/env ruby")

      patched = content.sub(
        %r{(#!/usr/bin/env ruby\n)\n(require 'rubygems')},
        "\\1#\n# This file was generated by RubyGems.\n#\n\\2"
      )
      if patched != content
        File.write(exe, patched)
        patched_count += 1
        ohai "  Patched: #{File.basename(exe)}"
      end
    end
    ohai "Patched #{patched_count} executables"

    abi_version = `#{bin}/ruby -rrbconfig -e 'print RbConfig::CONFIG["ruby_version"]'`
    abi_arch = `#{bin}/ruby -rrbconfig -e 'print RbConfig::CONFIG["arch"]'`

    if OS.linux?
      # Don't restrict to a specific GCC compiler binary we used (e.g. gcc-5).
      inreplace lib/"ruby/#{abi_version}/#{abi_arch}/rbconfig.rb" do |s|
        s.gsub! ENV.cxx, "c++"
        s.gsub! ENV.cc, "cc"
        # Change e.g. `CONFIG["AR"] = "gcc-ar-11"` to `CONFIG["AR"] = "ar"`
        s.gsub!(/(CONFIG\[".+"\] = )"gcc-(.*)-\d+"/, '\\1"\\2"')
        # C++ compiler might have been disabled because we break it with glibc@* builds
        s.sub!(/(CONFIG\["CXX"\] = )"false"/, '\\1"c++"') if build.without? "yjit"
      end
    end

    # Copy headers, static libraries, and pkg-config files for native gem compilation
    portable_deps = [libyaml, openssl]
    portable_deps += [libffi, zlib, libxcrypt] if OS.linux?
    copy_portable_deps_for_native_gems(portable_deps)
    patch_rbconfig_for_portable_native_gems(abi_version, abi_arch)

    # Bundle CA certificates for environments without system certs (e.g. minimal containers).
    # portable-openssl auto-detects system cert paths at the C level, but if none exist,
    # this bundled cert.pem provides a last-resort fallback via SSL_CERT_FILE.
    libexec.mkpath
    cp openssl.libexec/"etc/openssl/cert.pem", libexec/"cert.pem"
    openssl_rb = lib/"ruby/#{abi_version}/openssl.rb"
    inreplace openssl_rb, "require 'openssl.so'", <<~EOS.chomp
      # Fall back to bundled CA certificates only when no system certs exist.
      # System cert auto-detection is handled at the C level in portable-openssl;
      # this only activates for minimal environments (e.g. containers without ca-certificates).
      if ENV["SSL_CERT_FILE"].to_s.empty? && ENV["SSL_CERT_DIR"].to_s.empty?
        jdx_cert_file = ENV["JDX_RUBY_SSL_CERT_FILE"].to_s
        if !jdx_cert_file.empty? && File.exist?(jdx_cert_file)
          ENV["SSL_CERT_FILE"] = jdx_cert_file
        else
          jdx_cert_dir = ENV["JDX_RUBY_SSL_CERT_DIR"].to_s
          ENV["SSL_CERT_DIR"] = jdx_cert_dir if !jdx_cert_dir.empty? && Dir.exist?(jdx_cert_dir)
        end
      end
      if ENV["SSL_CERT_FILE"].to_s.empty? && ENV["SSL_CERT_DIR"].to_s.empty?
        system_certs = %w[
          /etc/ssl/certs/ca-certificates.crt
          /etc/pki/tls/certs/ca-bundle.crt
          /etc/ssl/ca-bundle.pem
          /opt/homebrew/etc/openssl@3/cert.pem
          /usr/local/etc/openssl@3/cert.pem
          /opt/homebrew/etc/ca-certificates/cert.pem
          /usr/local/etc/ca-certificates/cert.pem
          /home/linuxbrew/.linuxbrew/etc/openssl@3/cert.pem
          /home/linuxbrew/.linuxbrew/etc/ca-certificates/cert.pem
          /etc/ssl/cert.pem
        ]
        unless system_certs.any? { |f| File.exist?(f) }
          bundled = File.expand_path("../../libexec/cert.pem", RbConfig.ruby)
          ENV["SSL_CERT_FILE"] = bundled if File.exist?(bundled)
        end
      end
      \\0
    EOS
  end

  def test
    cp_r Dir["#{prefix}/*"], testpath
    ENV["PATH"] = "/usr/bin:/bin"
    ruby = (testpath/"bin/ruby").realpath
    assert_equal version.to_s.split("-").first, shell_output("#{ruby} -e 'puts RUBY_VERSION'").chomp
    assert_equal ruby.to_s, shell_output("#{ruby} -e 'puts RbConfig.ruby'").chomp
    assert_equal "3632233996",
      shell_output("#{ruby} -rzlib -e 'puts Zlib.crc32(\"test\")'").chomp
    # libedit has fewer word break characters than readline
    assert_includes [" \t\n\"\\'`@$><=;|&{(", " \t\n`><=;|&{("],
      shell_output("#{ruby} -rreadline -e 'puts Readline.basic_word_break_characters'").chomp
    assert_equal '{"a"=>"b"}',
      shell_output("#{ruby} -ryaml -e 'puts YAML.load(\"a: b\")'").chomp
    assert_equal "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      shell_output("#{ruby} -ropenssl -e 'puts OpenSSL::Digest::SHA256.hexdigest(\"\")'").chomp
    assert_match "200",
      shell_output("#{ruby} -ropen-uri -e 'URI.open(\"https://google.com\") { |f| puts f.status.first }'").chomp
    # 2.7: no `debug` gem (lib/debug.rb is the old interactive debugger) and
    # no injected bootsnap, so only check fiddle and the load-path helper.
    system ruby, "-rrbconfig", "-e", <<~EOS
      require "portable_ruby_gems"
      require "fiddle"
    EOS
    system testpath/"bin/gem", "environment"
    # Homebrew's vendored bundler leaks BUNDLER_VERSION (4.x) into the test
    # environment; 2.7's RubyGems honors it in find_spec_for_exe and aborts,
    # since bundler 4 does not support ruby 2.7 (3.x RubyGems doesn't use
    # this code path).
    ENV.delete "BUNDLER_VERSION"
    system testpath/"bin/bundle", "init"
    assert_match "# Object < BasicObject",
      shell_output("#{ruby} #{testpath}/bin/ri -T -f markdown Object")
    # install gem with native components (resolves to byebug 11.x on 2.7)
    system testpath/"bin/gem", "install", "byebug"
    assert_match "byebug",
      shell_output("#{testpath}/bin/byebug --version")

    # Test gems that require portable dependency headers
    # These were failing before we included headers in the tarball
    # See: https://github.com/jdx/mise/discussions/7268#discussioncomment-15298593
    # openssl gem 3.1.x is the newest line supporting ruby 2.7 + OpenSSL 1.1.1
    system testpath/"bin/gem", "install", "openssl", "-v", "~> 3.1.0"
    system testpath/"bin/gem", "install", "psych"    # requires libyaml headers

    super
  end
end
