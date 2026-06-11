require File.expand_path("../Abstract/portable-formula", __dir__)

# OpenSSL 1.1.1 (EOL upstream) exists solely for portable rubies <= 3.0,
# whose bundled openssl extension cannot build against OpenSSL 3.x.
# No livecheck: 1.1.1w is the final 1.1.1 release.
class PortableOpensslAT111w < PortableFormula
  desc "Cryptography and SSL/TLS Toolkit"
  homepage "https://openssl.org/"
  url "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz"
  mirror "https://www.openssl.org/source/old/1.1.1/openssl-1.1.1w.tar.gz"
  sha256 "cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8"
  license "OpenSSL"

  resource "cacert" do
    # https://curl.se/docs/caextract.html
    url "https://curl.se/ca/cacert-2025-07-15.pem"
    sha256 "7430e90ee0cdca2d0f02b1ece46fbf255d5d0408111f009638e3b892d6ca089c"

    livecheck do
      url "https://curl.se/ca/cadate.t"
      regex(/^#define\s+CA_DATE\s+(.+)$/)
      strategy :page_match do |page, regex|
        match = page.match(regex)
        next if match.blank?

        Date.parse(match[1]).iso8601
      end
    end
  end

  def openssldir
    libexec/"etc/openssl"
  end

  def arch_args
    if OS.mac?
      %W[darwin64-#{Hardware::CPU.arch}-cc enable-ec_nistp_64_gcc_128]
    elsif Hardware::CPU.intel?
      if Hardware::CPU.is_64_bit?
        ["linux-x86_64"]
      else
        ["linux-elf"]
      end
    elsif Hardware::CPU.arm?
      if Hardware::CPU.is_64_bit?
        ["linux-aarch64"]
      else
        ["linux-armv4"]
      end
    end
  end

  def configure_args
    # no-legacy/no-module from the 3.x formula don't exist in 1.1.1
    # (providers are an OpenSSL 3 concept); the rest matches Homebrew's
    # historical portable-openssl 1.1.1 used by portable-ruby <= 3.1.
    %W[
      --prefix=#{prefix}
      --openssldir=#{openssldir}
      --libdir=#{lib}
      no-ssl3
      no-ssl3-method
      no-zlib
      no-shared
      no-comp
      no-dynamic-engine
      no-makedepend
    ]
  end

  def install
    # Same runtime certificate auto-detection as portable-openssl@3.5.5
    # (see that formula for the full rationale). 1.1.1's x509_def.c has
    # simpler function bodies, hence different patch targets.
    # ossl_safe_getenv is declared in internal/cryptlib.h, already included.
    inreplace "crypto/x509/x509_def.c", <<~ORIG.chomp, <<~PATCHED.chomp
      #include <openssl/x509.h>
    ORIG
      #include <openssl/x509.h>
      #include <unistd.h>
    PATCHED

    inreplace "crypto/x509/x509_def.c", <<~ORIG.chomp, <<~PATCHED.chomp
      const char *X509_get_default_cert_file(void)
      {
          return X509_CERT_FILE;
      }
    ORIG
      const char *X509_get_default_cert_file(void)
      {
          const char *jdx_cert_file = ossl_safe_getenv("JDX_RUBY_SSL_CERT_FILE");
          if (jdx_cert_file != NULL && jdx_cert_file[0] != '\\0' && access(jdx_cert_file, R_OK) == 0)
              return jdx_cert_file;
          /* Auto-detect system certificate bundles */
          static const char *system_cert_files[] = {
              "/etc/ssl/certs/ca-certificates.crt", /* Debian/Ubuntu */
              "/etc/pki/tls/certs/ca-bundle.crt",   /* RHEL/CentOS/Fedora */
              "/etc/ssl/ca-bundle.pem",              /* SUSE */
              "/opt/homebrew/etc/openssl@3/cert.pem",        /* Homebrew OpenSSL on Apple Silicon */
              "/usr/local/etc/openssl@3/cert.pem",           /* Homebrew OpenSSL on Intel macOS */
              "/opt/homebrew/etc/ca-certificates/cert.pem", /* Homebrew on Apple Silicon */
              "/usr/local/etc/ca-certificates/cert.pem",    /* Homebrew on Intel macOS */
              "/home/linuxbrew/.linuxbrew/etc/openssl@3/cert.pem", /* Linuxbrew OpenSSL */
              "/home/linuxbrew/.linuxbrew/etc/ca-certificates/cert.pem", /* Linuxbrew */
              "/etc/ssl/cert.pem",                         /* macOS/Alpine */
              NULL
          };
          for (int i = 0; system_cert_files[i] != NULL; i++) {
              if (access(system_cert_files[i], R_OK) == 0)
                  return system_cert_files[i];
          }
          return X509_CERT_FILE;
      }
    PATCHED

    inreplace "crypto/x509/x509_def.c", <<~ORIG.chomp, <<~PATCHED.chomp
      const char *X509_get_default_cert_dir(void)
      {
          return X509_CERT_DIR;
      }
    ORIG
      const char *X509_get_default_cert_dir(void)
      {
          const char *jdx_cert_dir = ossl_safe_getenv("JDX_RUBY_SSL_CERT_DIR");
          if (jdx_cert_dir != NULL && jdx_cert_dir[0] != '\\0' && access(jdx_cert_dir, R_OK) == 0)
              return jdx_cert_dir;
          /* Auto-detect system certificate directories */
          static const char *system_cert_dirs[] = {
              "/etc/ssl/certs",          /* Debian/Ubuntu/Alpine/SUSE */
              "/etc/pki/tls/certs",      /* RHEL/CentOS/Fedora */
              "/opt/homebrew/etc/openssl@3/certs", /* Homebrew OpenSSL on Apple Silicon */
              "/usr/local/etc/openssl@3/certs", /* Homebrew OpenSSL on Intel macOS */
              "/home/linuxbrew/.linuxbrew/etc/openssl@3/certs", /* Linuxbrew OpenSSL */
              NULL
          };
          for (int i = 0; system_cert_dirs[i] != NULL; i++) {
              if (access(system_cert_dirs[i], R_OK) == 0)
                  return system_cert_dirs[i];
          }
          return X509_CERT_DIR;
      }
    PATCHED

    openssldir.mkpath
    system "perl", "./Configure", *(configure_args + arch_args)
    system "make"

    system "make", "install_dev"

    # Ruby doesn't support passing --static to pkg-config.
    # Unfortunately, this means we need to modify the OpenSSL pc file.
    # This is a Ruby bug - not an OpenSSL one.
    inreplace lib/"pkgconfig/libcrypto.pc", "\nLibs.private:", ""

    cacert = resource("cacert")
    filename = Pathname.new(cacert.url).basename
    openssldir.install cacert.files(filename => "cert.pem")
  end

  test do
    (testpath/"test.c").write <<~EOS
      #include <openssl/evp.h>
      #include <stdio.h>
      #include <string.h>

      int main(int argc, char *argv[])
      {
        if (argc < 2)
          return -1;

        unsigned char md[EVP_MAX_MD_SIZE];
        unsigned int size;

        if (!EVP_Digest(argv[1], strlen(argv[1]), md, &size, EVP_sha256(), NULL))
          return 1;

        for (unsigned int i = 0; i < size; i++)
          printf("%02x", md[i]);
        return 0;
      }
    EOS
    system ENV.cc, "test.c", "-L#{lib}", "-lcrypto", "-o", "test"
    assert_equal "717ac506950da0ccb6404cdd5e7591f72018a20cbca27c8a423e9c9e5626ac61",
                 shell_output("./test 'This is a test string'")
  end
end
