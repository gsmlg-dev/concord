{ pkgs, lib, config, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  env.GREET = "Concord";

  git-hooks.configPath = ".pre-commit-config.yaml";

  packages = with pkgs-stable; [
    git
    figlet
    lolcat
    openssl
    pkg-config
    watchman
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam27Packages.elixir;

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  enterShell = ''
    hello
  '';

}
