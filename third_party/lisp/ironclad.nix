{ depot, pkgs, ... }:

let
  inherit (pkgs) runCommand;
  inherit (depot.nix.buildLisp) bundled;
  src = with pkgs; srcOnly sbcl.pkgs.ironclad;
  getSrc = f: "${src}/src/${f}";

in
depot.nix.buildLisp.library {
  name = "ironclad";

  deps = with depot.third_party.lisp; [
    (bundled "asdf")
    { sbcl = bundled "sb-rotate-byte"; }
    { sbcl = bundled "sb-posix"; }
    alexandria
    bordeaux-threads
    nibbles
  ];

  srcs = map getSrc [
    # {
    #   # TODO(grfn): Figure out how to get this compiling with the assembly
    #   # optimization eventually - see https://cl.tvl.fyi/c/depot/+/1333
    #   sbcl = runCommand "package.lisp" {} ''
    #     substitute ${src}/src/package.lisp $out \
    #       --replace \#-ecl-bytecmp "" \
    #       --replace '(pushnew :ironclad-assembly *features*)' ""
    #   '';
    #   default = getSrc "package.lisp";
    # }
    "package.lisp"
    "conditions.lisp"
    "generic.lisp"
    "macro-utils.lisp"
    "util.lisp"
  ] ++ [
    { sbcl = getSrc "opt/sbcl/fndb.lisp"; }
    { sbcl = getSrc "opt/sbcl/cpu-features.lisp"; }
    { sbcl = getSrc "opt/sbcl/x86oid-vm.lisp"; }

    { ecl = getSrc "opt/ecl/c-functions.lisp"; }

    { ccl = getSrc "opt/ccl/x86oid-vm.lisp"; }
  ] ++ map getSrc [
    "common.lisp"

    "ciphers/cipher.lisp"
    "ciphers/padding.lisp"
    "ciphers/make-cipher.lisp"
    "ciphers/modes.lisp"

    # subsystem def ironclad/ciphers
    "ciphers/aes.lisp"
    "ciphers/arcfour.lisp"
    "ciphers/aria.lisp"
    "ciphers/blowfish.lisp"
    "ciphers/camellia.lisp"
    "ciphers/cast5.lisp"
    "ciphers/chacha.lisp"
    "ciphers/des.lisp"
    "ciphers/idea.lisp"
    "ciphers/kalyna.lisp"
    "ciphers/kuznyechik.lisp"
    "ciphers/misty1.lisp"
    "ciphers/rc2.lisp"
    "ciphers/rc5.lisp"
    "ciphers/rc6.lisp"
    "ciphers/salsa20.lisp"
    "ciphers/keystream.lisp"
    "ciphers/seed.lisp"
    "ciphers/serpent.lisp"
    "ciphers/sm4.lisp"
    "ciphers/sosemanuk.lisp"
    "ciphers/square.lisp"
    "ciphers/tea.lisp"
    "ciphers/threefish.lisp"
    "ciphers/twofish.lisp"
    "ciphers/xchacha.lisp"
    "ciphers/xor.lisp"
    "ciphers/xsalsa20.lisp"
    "ciphers/xtea.lisp"

    "digests/digest.lisp"
    # subsystem def ironclad/digests
    "digests/adler32.lisp"
    "digests/blake2.lisp"
    "digests/blake2s.lisp"
    "digests/crc24.lisp"
    "digests/crc32.lisp"
    "digests/groestl.lisp"
  ] ++ [
    {
      # Work around compiler warning for CCL:
      # https://github.com/sharplispers/ironclad/commit/ebc994b06409829c463b099fe460276cba564d43#commitcomment-153059140
      ccl = pkgs.runCommand "jh.lisp" { } ''
        substitute "${src}/src/digests/jh.lisp" "$out" \
          --replace-fail "(declare (notinline jh-buffer jh-state))" ""
      '';
      default = "${src}/src/digests/jh.lisp";
    }
  ] ++ map getSrc [
    "digests/kupyna.lisp"
    "digests/md2.lisp"
    "digests/md4.lisp"
    "digests/md5.lisp"
    "digests/md5-lispworks-int32.lisp"
    "digests/ripemd-128.lisp"
    "digests/ripemd-160.lisp"
    "digests/sha1.lisp"
    "digests/sha256.lisp"
    "digests/sha3.lisp"
    "digests/sha512.lisp"
    "digests/skein.lisp"
    "digests/sm3.lisp"
    "digests/streebog.lisp"
    "digests/tiger.lisp"
    "digests/tree-hash.lisp"
    "digests/whirlpool.lisp"

    "macs/mac.lisp"
    # subsystem def ironclad/macs
    "macs/blake2-mac.lisp"
    "macs/blake2s-mac.lisp"
    "macs/cmac.lisp"
    "macs/hmac.lisp"
    "macs/gmac.lisp"
    "macs/poly1305.lisp"
    "macs/siphash.lisp"
    "macs/skein-mac.lisp"

    "prng/prng.lisp"
    "prng/os-prng.lisp"
    "prng/generator.lisp"
    "prng/fortuna.lisp"

    "math.lisp"

    "octet-stream.lisp"

    "aead/aead.lisp"
    # subsystem def ironclad/aead
    "aead/eax.lisp"
    "aead/etm.lisp"
    "aead/gcm.lisp"

    "kdf/kdf.lisp"
    # subsystem def ironclad/kdfs
    "kdf/argon2.lisp"
    "kdf/bcrypt.lisp"
    "kdf/hmac.lisp"
    "kdf/pkcs5.lisp"
    "kdf/password-hash.lisp"
    "kdf/scrypt.lisp"

    "public-key/public-key.lisp"
    "public-key/pkcs1.lisp"
    "public-key/elliptic-curve.lisp"
    # subsystem def ironclad/public-keys
    "public-key/dsa.lisp"
    "public-key/rsa.lisp"
    "public-key/elgamal.lisp"
    "public-key/curve25519.lisp"
    "public-key/curve448.lisp"
    "public-key/ed25519.lisp"
    "public-key/ed448.lisp"
    "public-key/secp256k1.lisp"
    "public-key/secp256r1.lisp"
    "public-key/secp384r1.lisp"
    "public-key/secp521r1.lisp"
  ];
}
