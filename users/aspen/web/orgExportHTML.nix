{ pkgs, depot, ... }:

with pkgs;
with lib;

opts:

let
  src = if isAttrs opts then opts.src else opts;
  headline = if isAttrs opts then opts.headline else null;
  configFile = opts.configFile or ./config.el;

  bn = builtins.baseNameOf src;
  filename = elemAt (splitString "." bn) 0;

  outName =
    if isNull headline
    then
      let
        bn = builtins.baseNameOf src;
        filename = elemAt (splitString "." bn) 0;
      in
      if depot.nix.utils.isDirectory src
      then filename
      else filename + ".html"
    else "${filename}-${replaceStrings [" "] ["-"] filename}.html";

  escapeDoubleQuotes = replaceStrings [ "\"" ] [ "\\\"" ];

  navToHeadline = optionalString (! isNull headline) ''
    (search-forward "${escapeDoubleQuotes headline}")
    (org-narrow-to-subtree)
  '';

in

runCommand outName { inherit src; } ''
  buildFile() {
    cp "$1" file.org
    ${pkgs.emacs}/bin/emacs --batch \
      --load ${configFile} \
      --visit file.org \
      --eval "(progn
        ${escapeDoubleQuotes navToHeadline}
        (org-html-export-to-html))" \
      --kill
    rm file.org
    substitute file.html "$2" \
      --replace-quiet '<title>&lrm;</title>' ""
    rm file.html
  }

  if [ -d $src ]; then
    for file in $src/*; do
      result=''${file/$src/$out}
      mkdir -p $(dirname $result)
      buildFile $file ''${result/.org/.html}
    done
  else
    buildFile $src $out
  fi
''
