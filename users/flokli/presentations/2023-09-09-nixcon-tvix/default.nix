{ depot, pkgs, ... }:

let
  inherit (pkgs)
    fontconfig qrencode runCommand stdenv;
  mkQr = url: runCommand "qrcode.png" { } ''
    ${qrencode}/bin/qrencode -o $out -t SVG -s 5 \
      --background=fafafa \
      --foreground=000000 \
      ${url}
  '';
in
stdenv.mkDerivation {
  name = "2023-nixcon-tvix";
  src = ./.;

  FONTCONFIG_FILE = pkgs.makeFontsConf {
    fontDirectories = with pkgs; [ jetbrains-mono fira fira-code fira-mono lato ];
  };

  nativeBuildInputs = [ pkgs.reveal-md pkgs.graphviz ];

  buildPhase = ''
    cp ${depot.tvix.logo}/logo.png tvix-logo.png
    dot -Tsvg crate-deps.dot > crate-deps.svg
    cp ${mkQr "https://flokli.de"} qrcode-flokli.svg
    cp ${mkQr "https://tvix.dev"} qrcode-tvix.svg

    mkdir -p $out
    reveal-md --static $out presentation.md
    cp tvixbolt.webm $out

    CHROME_CONFIG_HOME=/build/.config reveal-md presentation.md --print $out/slides.pdf --puppeteer-chromium-executable="${pkgs.chromium}/bin/chromium"
    # Above command doesn't fail on error, ensure file has been created
    [[ -f "$out/slides.pdf" ]] || exit 1
  '';

  # reveal-md presentation.md --print started timing out possibly due to
  # chromium: 133.0.6943.141 -> 134.0.6998.35
  meta.ci.skip = true;
}
