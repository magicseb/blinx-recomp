# Blinx: The Time Sweeper — recompilation statique

Portage PC de *Blinx: The Time Sweeper* (Xbox, version PAL), par
recompilation statique du code x86 de `default.xbe` en C, avec le toolkit
xboxrecomp : la branche
[`blinx` de ce fork](https://github.com/magicseb/xboxrecomp/tree/blinx)
(de [xenophobentx/xboxrecomp](https://github.com/xenophobentx/xboxrecomp)).

**Installation facile :** téléchargez
[BlinxSetup.exe](https://github.com/magicseb/blinx-recomp/releases/latest/download/BlinxSetup.exe)
([releases](https://github.com/magicseb/blinx-recomp/releases)), lancez-le et
donnez-lui votre ISO : il installe les outils, compile le jeu et crée un
raccourci sur le Bureau.

**Aucune donnée du jeu n'est fournie.** Il faut sa propre copie du disque ;
le code C recompilé est régénéré localement depuis votre `default.xbe` et
n'est pas dans ce dépôt.

## État

- Démarrage, vidéos d'intro (Sofdec, décodées par ffmpeg), écran titre avec
  sa vidéo de fond, démo et jeu.
- Manette USB émulée (pad XInput / SDL de l'hôte), son (APU émulé).
- Rendu GPU en Vulkan, résolution interne jusqu'à 4x, profondeur de champ
  correcte.
- Menu de réglages (Select+Start ou F1) : résolution, FXAA/SMAA, netteté,
  filtrage anisotrope, LOD, agrandissement des textures, plein écran.
- Le jeu tourne à son rythme d'origine (30 images/s en jeu) ; la cadence
  n'est pas encore régulière partout.

Les notes de mise au point détaillées sont dans [docs/BRINGUP.md](docs/BRINGUP.md).

## Construire (Windows)

Prérequis : Python avec `capstone` (`python -m pip install capstone`),
`ffmpeg` dans le PATH pour les vidéos, et ce dépôt à côté du toolkit :

```
XBOX-PROJECT/
  BLINX/          ce dépôt
  xboxrecomp/     le toolkit : git clone -b blinx https://github.com/magicseb/xboxrecomp
  deps/           llvm-mingw, SDL2, Vulkan, glslang (tools/win/fetch-deps.sh)
```

```bash
# 1. Extraire le disque dans game_files/
(cd ../xboxrecomp && python -m tools.xiso unpack "<votre ISO>" -o ../BLINX/game_files/)

# 2. Régénérer le C depuis default.xbe (~12 min la première fois)
FABLE_XBE="$PWD/game_files/default.xbe" PYTHON=python ./regen.sh --disasm

# 3. Compiler (llvm-mingw, SDL2 + Vulkan)
bash tools/win/fetch-deps.sh
BUILD_DIR=build/mingw bash tools/win/build-mingw.sh -DBLINX_WIN_VULKAN=ON \
    -DCMAKE_C_FLAGS="-I$(cygpath -m ../xboxrecomp/src/kernel)"

# 4. Lancer
cd build/mingw && ./blinx_recomp.exe
```

## Commandes

- Manette : comme sur Xbox ; Select+Start ouvre les réglages.
- Clavier : F1 ouvre les réglages.

## Licence

Le code de ce dépôt est sous licence [MIT](LICENSE). Elle ne couvre pas le
jeu : *Blinx: The Time Sweeper* et ses données appartiennent à leurs
ayants droit.

## Remerciements

Le toolkit xboxrecomp (sp00nz, xenophobentx et ses contributeurs), Takedawn
pour son menu de réglages, et xemu comme référence.
