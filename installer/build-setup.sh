#!/usr/bin/env bash
# Build installer/BlinxSetup.exe: setup.c with BlinxSetup.ps1 inside it.
# Needs the llvm-mingw of ../deps (tools/win/fetch-deps.sh) and python.
#
#   bash installer/build-setup.sh      ->  build/BlinxSetup.exe
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
D="${BLINX_WINDEPS:-$ROOT/../deps}"
OUT="$ROOT/build/setup"
mkdir -p "$OUT"

# The script as a C array.
python - "$HERE/BlinxSetup.ps1" "$OUT/setup_script.h" <<'EOF'
import sys
data = open(sys.argv[1], 'rb').read()
with open(sys.argv[2], 'w') as f:
    f.write('static const unsigned char k_script[] = {\n')
    for i in range(0, len(data), 16):
        f.write('  ' + ','.join(str(b) for b in data[i:i + 16]) + ',\n')
    f.write('};\nstatic const unsigned long k_script_len = %d;\n' % len(data))
EOF

# The same green disc icon the installed launcher gets, drawn by PowerShell.
powershell -NoProfile -Command "
Add-Type -AssemblyName System.Drawing
\$bmp = New-Object System.Drawing.Bitmap 256, 256
\$g = [System.Drawing.Graphics]::FromImage(\$bmp)
\$g.SmoothingMode = 'AntiAlias'; \$g.TextRenderingHint = 'AntiAliasGridFit'
\$r = New-Object System.Drawing.Rectangle 8, 8, 240, 240
\$b = New-Object System.Drawing.Drawing2D.LinearGradientBrush \$r, ([System.Drawing.Color]::FromArgb(255,155,224,60)), ([System.Drawing.Color]::FromArgb(255,16,124,16)), 90
\$g.FillEllipse(\$b, \$r)
\$g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255,6,48,8)), 10), 13, 13, 230, 230)
\$f = New-Object System.Drawing.Font 'Segoe UI', 120, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
\$sf = New-Object System.Drawing.StringFormat; \$sf.Alignment = 'Center'; \$sf.LineAlignment = 'Center'
\$g.DrawString('B', \$f, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 6, 256, 256), \$sf)
\$ms = New-Object System.IO.MemoryStream; \$bmp.Save(\$ms, [System.Drawing.Imaging.ImageFormat]::Png); \$p = \$ms.ToArray()
\$o = New-Object System.IO.MemoryStream; \$w = New-Object System.IO.BinaryWriter \$o
\$w.Write([UInt16]0); \$w.Write([UInt16]1); \$w.Write([UInt16]1)
\$w.Write([Byte]0); \$w.Write([Byte]0); \$w.Write([Byte]0); \$w.Write([Byte]0)
\$w.Write([UInt16]1); \$w.Write([UInt16]32); \$w.Write([UInt32]\$p.Length); \$w.Write([UInt32]22); \$w.Write(\$p); \$w.Flush()
[System.IO.File]::WriteAllBytes('$(cygpath -w "$OUT/setup.ico")', \$o.ToArray())
"
echo '1 ICON "setup.ico"' > "$OUT/setup.rc"
(cd "$OUT" && "$D/llvm-mingw/bin/x86_64-w64-mingw32-windres" setup.rc -O coff -o setup.res)
"$D/llvm-mingw/bin/x86_64-w64-mingw32-clang" -O2 -municode -I"$OUT" \
    "$HERE/setup.c" "$OUT/setup.res" -o "$ROOT/build/BlinxSetup.exe"
ls -l "$ROOT/build/BlinxSetup.exe"
