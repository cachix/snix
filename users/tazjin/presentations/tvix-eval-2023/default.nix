{ depot, pkgs, ... }:

let
  inherit (pkgs) fontconfig texlive stdenv imagemagick runCommand qrencode;

  tex = texlive.combine {
    inherit (texlive)
      babel
      babel-russian
      beamer
      beamertheme-metropolis
      etoolbox
      euenc
      extsizes
      fontspec
      listings
      xetex
      minted
      count1to
      multitoc
      prelim2e
      ragged2e
      pgfopts
      scheme-basic
      translator;
  };

  linksQrCode = runCommand "qrcode.png" { } ''
    ${qrencode}/bin/qrencode -o code.png -s 8 \
      --background=fafafa \
      --foreground=000000 \
      'https://tazj.in/blog/tvix-eval-talk-2023'

    # latex has trouble with the PDF produced by qrencode
    ${imagemagick}/bin/convert code.png $out
  '';
in
stdenv.mkDerivation {
  name = "progmsk-tvix-eval";
  src = ./.;

  nativeBuildInputs = [ tex imagemagick fontconfig ];

  FONTCONFIG_FILE = pkgs.makeFontsConf {
    fontDirectories = with pkgs; [ jetbrains-mono fira fira-code fira-mono ];
  };

  buildPhase = ''
    # LaTeX needs a cache folder in /home/ ...
    mkdir home
    export HOME=$PWD/home

    cp ${depot.tvix.logo}/logo.png tvix-logo.png
    cp ${linksQrCode} qrcode.png

    # As usual, TeX needs to be run twice ...
    ${tex}/bin/xelatex presentation.tex
    ${tex}/bin/xelatex presentation.tex
  '';

  installPhase = ''
    mkdir -p $out
    cp presentation.pdf $out/
    cp $src/presentation.pdfpc $out/
  '';
}
