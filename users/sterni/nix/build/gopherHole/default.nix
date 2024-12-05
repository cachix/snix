{ depot, pkgs, lib, ... }:

let
  inherit (pkgs)
    runCommand
    writeText
    ;

  buildGopherHole = depot.users.sterni.nix.build.gopherHole;

  fileTypes = {
    # RFC1436
    text = "0";
    menu = "1";
    cso = "2";
    error = "3";
    binhex = "4";
    dos = "5";
    uuencoded = "6";
    index-server = "7";
    telnet = "8";
    binary = "9";
    mirror = "+";
    gif = "g";
    image = "I";
    tn3270 = "T";
    # non-standard
    info = "i";
    html = "h";
  };

  buildFile = { file, name, fileType ? fileTypes.text }:
    runCommand name
      {
        passthru = {
          # respect the file type the file derivation passes
          # through. otherwise use explicitly set type or
          # default value.
          fileType = file.fileType or fileType;
        };
      } ''
      ln -s ${file} "$out"
    '';

  buildGopherMap = dir:
    let
      /* strings constitute an info line or an empty line
         if their length is zero. sets that contain a menu
         value have that added to the gophermap as-is.

         all other entries should be a set which can be built using
         buildGopherHole and is linked by their name. The resulting
         derivation is expected to passthru a fileType containing the
         gopher file type char of themselves.
      */
      gopherMapLine = e:
        if builtins.isString e
        then e
        else if e ? menu
        then e.menu
        else
          let
            drv = buildGopherHole e;
            title = e.title or e.name;
          in
          "${drv.fileType}${title}\t${drv.name}";
    in
    writeText ".gophermap" (lib.concatMapStringsSep "\n" gopherMapLine dir);

  buildDir =
    { dir, name, ... }:

    let
      # filter all entries out that have to be symlinked:
      # sets with the file or dir attribute
      drvOnly = builtins.map buildGopherHole (builtins.filter
        (x: !(builtins.isString x) && (x ? dir || x ? file))
        dir);
      gopherMap = buildGopherMap dir;
    in
    runCommand name
      {
        passthru = {
          fileType = fileTypes.dir;
        };
      }
      (''
        mkdir -p "$out"
        ln -s "${gopherMap}" "$out/.gophermap"
      '' + lib.concatMapStrings
        (drv: ''
          ln -s "${drv}" "$out/${drv.name}"
        '')
        drvOnly);
in

{
  # Dispatch into different file / dir handling code
  # which is mutually recursive with this function.
  __functor = _: args:
    if args ? file then buildFile args
    else if args ? dir then buildDir args
    else builtins.throw "Unrecognized gopher hole item type: "
      + lib.generators.toPretty { } args;

  inherit fileTypes;
}
