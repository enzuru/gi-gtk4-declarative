{
  description = "gi-gtk4-declarative - declarative GTK4 programming in Haskell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

      # The C libraries the generated bindings dlopen at run time.  haskell-gi
      # records bare sonames (libgtk-4.so.1, ...) in the typelibs, and there is
      # no /usr/lib on NixOS, so the loader has to be told where they live.
      runtimeLibs = pkgs: with pkgs; [
        glib gtk4 pango gdk-pixbuf graphene harfbuzz cairo
        gobject-introspection
      ];

      # nixpkgs' gi-gtk is the 4.x binding, which is the package the cabal
      # files name; gi-gtk3 is the old one, and gi-gtk4 is a second copy of
      # the same thing under another name.  The Makefile hides that copy,
      # because two packages holding a module called GI.Gtk make every
      # import of it ambiguous.
      haskellDeps = ps: with ps; [
        base containers data-default-class mtl text unordered-containers vector
        bytestring async stm safe-exceptions hedgehog hspec
        pipes pipes-concurrency pipes-extras
        haskell-gi haskell-gi-base haskell-gi-overloading
        gi-glib gi-gobject gi-gio gi-gdk gi-gtk gi-gsk gi-pango gi-cairo
        criterion
      ];
    in {
      devShells = forAll (pkgs:
        let
          ghc = pkgs.haskellPackages.ghcWithPackages haskellDeps;
          runtime = runtimeLibs pkgs;
        in {
          # The documentation site, which needs Python rather than GHC.
          docs = pkgs.mkShell {
            packages = [
              (pkgs.python3.withPackages
                (ps: [ ps.mkdocs ps.mkdocs-material ]))
            ];
          };

          default = pkgs.mkShell {
            packages = with pkgs; [
              ghc
              cabal-install
              gnumake pkg-config
              gtk4 gtk4.dev gobject-introspection
              adwaita-icon-theme hicolor-icon-theme
              xvfb-run xdotool dbus
            ];

            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtime;
            # "out", not the default output: glib and pango default to "bin",
            # which has no girepository-1.0 directory.
            GI_TYPELIB_PATH = pkgs.lib.makeSearchPath "lib/girepository-1.0"
              (map (p: pkgs.lib.getOutput "out" p) runtime);

            shellHook = ''
              export XDG_DATA_DIRS="${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name}:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.adwaita-icon-theme}/share:${pkgs.hicolor-icon-theme}/share:${pkgs.gtk4}/share:$XDG_DATA_DIRS"
              echo "gi-gtk4-declarative dev shell -- run 'make check'"
            '';
          };
        });
    };
}
