# Blinx: The Time Sweeper — notes de bring-up

État au 24 octobre 2026 (nuit) : le jeu démarre, affiche l'écran de chargement,
le logo Xbox, saute les vidéos d'intro, puis rend la cinématique in-engine,
l'écran titre (« Jouer la démo. ») et la démo d'attract (round 1) pendant plus
de 10 minutes sans plantage. Vblank à 60 Hz, aucun refus d'interruption.
Captures dans `docs/screenshots/`.

Non vérifié : la manette (Start à l'écran titre), le son, le vrai gameplay,
les vidéos Sofdec (sautées, voir plus bas).

## Construire et lancer (hôte GDI + Direct3D 11)

```bash
# Régénérer le C depuis default.xbe (désassemblage complet ~8 min + recomp ~2 min)
FABLE_XBE="$PWD/game_files/default.xbe" PYTHON=python ./regen.sh --disasm

# Compiler (llvm-mingw dans ../deps, cible blinx_recomp)
BUILD_DIR=build/d3d11 bash tools/win/build-mingw.sh -DBLINX_WIN_VULKAN=OFF \
    -DCMAKE_C_FLAGS="-gline-tables-only -DRECOMP_ICALL_FEEDBACK -I$(cygpath -m ../xboxrecomp/src/kernel)"

# Lancer depuis bash (pas PowerShell -RedirectStandardError : le pipe vers
# powershell.exe ralentit chaque fprintf et le jeu tombe à 2 fps)
cd build/d3d11 && ./blinx_recomp.exe >stdout.txt 2>stderr.txt
```

`build/d3d11/game` est une jonction vers `game_files` (ISO décompressée).
La build SDL2 + Vulkan (`build/mingw`, `-DBLINX_WIN_VULKAN=ON`) existe mais
n'est pas celle qui a été déboguée.

Variables utiles : `RECOMP_STUB_LOG=1` (chaque stub de cible non résolue
atteint, une fois), `RECOMP_FB_DUMP=prefix` + `RECOMP_FB_WINDOW_DUMP_EVERY=n`
(dumps BMP de la fenêtre), `BLINX_STACK_SAMPLE=s` (piles natives de tous les
threads toutes les s secondes ; `llvm-addr2line -e blinx_recomp.exe` les
traduit en `recomp_XXXX.c:ligne`, donc en adresse Xbox grâce aux
`-gline-tables-only`), `BLINX_DIAG_TABLE=1` (thread de diagnostic : table de
callbacks du titre, flags du loader, dump périodique des cibles d'appels
indirects dans `icall.txt`).

## Fonctions graines (`config/seed_functions.json`)

Le désassembleur ne trouve pas les fonctions atteintes seulement par pointeur
(ISR, callbacks, vtables, entrées de sections). Le recompilateur les remplace
alors par des stubs silencieux. Symptômes : `[ICALL] Failed to resolve VA`
dans le log (cible absente du dispatch) ou `[STUB] unresolved ... reached`
avec `RECOMP_STUB_LOG=1`. Chaque adresse va dans le fichier de graines, puis
`./regen.sh --disasm`. Les plus importantes :

- `0x0013B6F0` ISR vblank D3D (sans elle : « ISR not callable », une image
  puis plus rien) ;
- `0x000A06F0` callback vblank du titre (non résolu, le chemin d'échec ICALL
  décale la pile de 4 : l'épilogue de la DPC restaurait `ebx/edi` depuis les
  mauvais emplacements et le masque d'interruption restait à 0 → 2 fps) ;
- `0x000FA310/350/3C0` les trois routines de threads du titre ;
- les vtables CRI Sofdec (`0x001CEAF0..0x001CEC98`), `mwPlyExecServer`
  (`0x0010D1D0`, atteint par un `jmp` après 15 NOP), les entrées des
  sections `PSGSFD_I/_P/00` ;
- une vingtaine de fonctions de gameplay découvertes au fil des runs.

## Overrides natifs (`src/recomp_manual.c`)

- `sub_00127E20` memmove du CRT (corps de tous les memcpy) : ses tables de
  sauts internes ne sont pas suivies ; lifté, chaque copie perdait son reste
  de 1 à 3 octets.
- Vidéos Sofdec (`media/movie/*.sfd`) : le décodeur CRI ne tourne pas (il
  appelle via une table à `0x00452000` jamais remplie). Elles sont lues côté
  hôte par `src/movie_player.c` : ffmpeg (PATH, ou `BLINX_FFMPEG`) décode la
  vidéo en BGRA 640×448 et le son en PCM 48 kHz, waveOut joue le son et sert
  d'horloge, et chaque image passe par `nv2a_pb_d3d11_movie_frame()` du
  toolkit, présentée à la place de l'image du jeu. PlayMovie
  (`sub_000C1620`), l'update (`sub_000C1810`) et StopMovie (`sub_000C17A0`)
  répondent depuis ce lecteur ; le flag `0x00503400` reste à 0. Start passe
  la vidéo (le jeu appelle StopMovie). Sans ffmpeg, les vidéos sont sautées.
  Les .sfd sans piste son (`end_a01`, `pr_a01` : son dans des .adx/.aix à
  part) sont cadencés sur l'horloge de l'hôte.

## Réglages dans `src/main.c`

- `xbox_SetMapSize(256 Mo)` : le XBE fait 49,7 Mo et le tas du titre dépasse
  la ligne des 64 Mo (lecture de 1 Mo de `3_plyrse.bin` refusée → écran
  « disque sale ou endommagé »).
- `xbox_Nv2aMirrorFence(0x00142058, 0x30, 0x34)` : device D3D8 (XDK 4831) ;
  sans ça le titre attend de la place dans le push buffer pour toujours.
- `RECOMP_FB_WINDOW=1` par défaut en D3D11 (la fenêtre est opt-in).
- Fenêtre, pads USB émulés, vblank émulé, APU : repris de Fable.

## Modifications du toolkit (`../xboxrecomp`, non commitées)

- `tools/recomp/lifter.py` : `pop` 16 bits ; `translator.py` : `scasd` nu
  déclare `_cf`.
- `src/kernel/kernel_thread.c` : `NtSuspendThread` coopératif (le thread
  visé s'arrête à son prochain appel noyau, jamais à DISPATCH_LEVEL ni en
  tenant un verrou hôte) + point sûr dans `kernel_thunk_dispatch`.
- `src/kernel/kernel_bridge.c` : miroir du `SignalState` des KEVENT (D3D
  remet l'événement vblank à zéro en écrivant la struct) ; `DbgPrint`
  toujours journalisé.
- `src/apu/CMakeLists.txt` : lien pthread pour la build D3D11.

## Rendu GPU (Direct3D 11) et profondeur de champ

`RECOMP_PB_BACKEND=d3d11` est le défaut (`src/main.c`) : le rendu logiciel
donnait ~1 image/s dans la démo.

La démo utilise une profondeur de champ : la scène est rendue hors écran
(`0x01000000`), une passe 320×240 (`0x01258000`) lit la scène **et le tampon
de profondeur `0x0112C000` comme une texture A8R8G8B8**, puis le résultat
flouté est mélangé à l'écran selon cet alpha. Le backend gardait la
profondeur uniquement sur le GPU : la passe lisait des octets périmés et
floutait tout (l'« effet fantôme »). Corrigé dans
`xboxrecomp/src/d3d/nv2a_pb_d3d11.c` (`zeta_texture`) : un compute shader
reconstruit les octets Z24S8 du matériel (A = bits 23..16, R = 15..8,
G = 7..0, B = stencil) quand une texture pointe sur un zeta.

Certains plans de la démo floutent volontairement l'arrière-plan (le jeu
change le seuil et inverse la sélection) ; Blinx peut encore y paraître un
peu flou parce que sa profondeur tombe pile sur le seuil — le matériel
calcule les combiners en virgule fixe 8 bits, nous en flottant.

Outil : `BLINX_FRAME_LOG=<present>` (+ `BLINX_FRAME_LOG_EVERY=n`,
`BLINX_FRAME_LOG_DIR=dossier`) journalise chaque passe (cible, textures,
mélange, combiner) et sauvegarde chaque cible de rendu et chaque profondeur
lue comme texture.

## Manette USB

Fonctionne (manette XInput de l'hôte, et le clavier avec `RECOMP_KEYBOARD=1` :
Entrée = Start). Trois causes, toutes corrigées :

1. L'allocateur contigu distribuait des pages physiques à l'intérieur de
   l'image (49,7 Mo sur 64) : l'OHCI lisait le HCCA et les ED/TD du pilote
   XPP dans les sections de modèles 3D. Les petits blocs (≤ 64 Ko) vont
   maintenant au-dessus de l'image (`xbox_ContiguousAllocEx`,
   `xboxrecomp/src/kernel/xbox_memory_layout.c`).
2. Deux routines du pilote XPP atteintes par pointeur : `0x00187334`
   (après SET_CONFIGURATION) et `0x00186A39` (complétion des rapports
   d'entrée), ajoutées aux graines.
3. (diagnostic) `RECOMP_USB_TRACE=1` / `RECOMP_USB_STATS=1` montrent les
   SETUP et le nombre de rapports servis ; `RECOMP_INPUT_DIAG=1` l'état de
   la manette hôte une fois par seconde.

## Performance en jeu

En jeu, Blinx fait des centaines de KickOff par image et chacun attend que le
thread nv2a-ack acquitte le flush (bit 16 de PFB `0x100410`). La sieste de
50 µs de ce thread (`kick_nap_us`, `xboxrecomp/src/kernel/xbox_memory_layout.c`)
était arrondie par Windows à ≥ 1 ms : environ une image par seconde. Les
siestes courtes sont maintenant une attente active (QPC + SwitchToThread) ;
le jeu est fluide.

## Pistes suivantes

1. Build Vulkan (la superposition des vidéos n'existe qu'en D3D11).
2. Continuer à semer les cibles `Failed to resolve` au fil des runs (boucle
   `RECOMP_ICALL_FEEDBACK` + `python -m tools.recomp.icall_feedback merge`).
