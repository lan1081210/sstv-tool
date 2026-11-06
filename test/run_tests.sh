#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Self-test: synthesize a test card in every mode, decode it, and check the
# picture that came out (image count, stored size, the decoder's own sync stats).
# Then a few impaired-signal cases: skew, noise, no VIS, two modes back to back.
set -u
cd "$(dirname "$0")/.." || exit 1

BIN=build/sstv-tool
TX=build/sstv_tx
OUT=test/out
mkdir -p "$OUT"

[ -x "$BIN" ] || { echo "build first: make"; exit 1; }
[ -x "$TX" ] || { echo "build first: make tools"; exit 1; }
[ -f "$OUT/testcard.ppm" ] || python3 test/gen_testcard.py "$OUT/testcard.ppm" 640 496 >/dev/null

pngsize() {  # $1 = png -> WxH
    python3 - "$1" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(33)
assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
print('%dx%d' % struct.unpack('>II', d[16:24]))
PY
}

fail=0
pass=0
ok()  { pass=$((pass+1)); printf '%-12s %-6s PASS  %s\n' "$1" "$2" "$3"; }
bad() { fail=$((fail+1)); printf '%-12s %-6s FAIL  %s\n' "$1" "$2" "$3"; }

check_mode() {  # name vis expected-WxH [extra sstv_tx args...]
    local name=$1 vis=$2 want=$3; shift 3
    local wav="$OUT/$name.wav" png="$OUT/$name-1.png"
    rm -f "$OUT/$name"-*.png
    "$TX" "$OUT/testcard.ppm" "$wav" --mode "$vis" "$@" >/dev/null 2>&1
    local log; log=$("$BIN" "$wav" --out "$OUT" 2>&1)
    if [ ! -f "$png" ]; then bad "$name" "$vis" "no image written"; return; fi
    local got; got=$(pngsize "$png")
    local detail; detail=$(echo "$log" | grep 'image ended' | sed 's/^ *[0-9.]* s  //')
    if [ "$got" = "$want" ] && echo "$log" | grep -q 'image ended (complete)'; then
        ok "$name" "$vis" "$got  $detail"
    else
        bad "$name" "$vis" "want $want got $got :: $detail"
    fi
}

echo "== every mode =="
check_mode Robot36    8  320x240
check_mode Robot72   12  320x240
check_mode MartinM1  44  320x256
check_mode MartinM2  40  320x256
check_mode ScottieS1 60  320x256
check_mode ScottieS2 56  320x256
check_mode ScottieDX 76  320x256
check_mode PD50      93  320x256
check_mode PD90      99  320x256
check_mode PD120     95  320x248
check_mode PD160     98  256x200
check_mode PD180     96  320x248
check_mode PD240     97  320x248
check_mode PD290     94  400x308

echo
echo "== impaired signals =="
# sender 400 ppm fast, mistuned by -40 Hz, noisy: must still finish and report ppm
check_mode PD120skew 95 320x248 --skew -400 --offset -40 --snr 18
grep -q "" /dev/null  # no-op keeps shellcheck quiet
# no VIS at all: the autosync path has to lock on by itself
check_mode PD120novis 95 320x248 --novis

# two pictures back to back in one file (VIS-less Robot 36 then PD90)
python3 - "$OUT" <<'PY'
import struct, sys, os
d = sys.argv[1]
def pcm(p):
    b = open(p, 'rb').read()
    i = b.find(b'data')
    n = struct.unpack('<I', b[i+4:i+8])[0]
    return b[i+8:i+8+n]
a, b = pcm(os.path.join(d, 'MartinM1.wav')), pcm(os.path.join(d, 'PD90.wav'))
body = a + b
with open(os.path.join(d, 'seq.wav'), 'wb') as f:
    f.write(b'RIFF' + struct.pack('<I', 36 + len(body)) + b'WAVEfmt ')
    f.write(struct.pack('<IHHIIHH', 16, 1, 1, 44100, 88200, 2, 16))
    f.write(b'data' + struct.pack('<I', len(body)))
    f.write(body)
print('seq.wav: %.1f s' % (len(body) / 2 / 44100))
PY
rm -f "$OUT"/seq-*.png
seqlog=$("$BIN" "$OUT/seq.wav" --out "$OUT" 2>&1)
nseq=$(ls "$OUT"/seq-*.png 2>/dev/null | wc -l | tr -d ' ')
if [ "$nseq" = "2" ] && echo "$seqlog" | grep -q 'Martin M1' && echo "$seqlog" | grep -q 'PD90'; then
    ok seq 44+99 "2 pictures: $(ls "$OUT"/seq-*.png | xargs -n1 basename | tr '\n' ' ')"
else
    bad seq 44+99 "pictures $nseq :: $(echo "$seqlog" | tr '\n' '|')"
fi

# four modes back to back in one stream, no pause: the decoder must switch
# mode on its own as each VIS arrives
python3 - "$OUT" <<'PY'
import struct, sys, os
d = sys.argv[1]
def pcm(p):
    b = open(p, 'rb').read()
    i = b.find(b'data')
    n = struct.unpack('<I', b[i+4:i+8])[0]
    return b[i+8:i+8+n]
body = b''.join(pcm(os.path.join(d, f)) for f in ('Robot36.wav', 'Robot72.wav', 'MartinM1.wav', 'MartinM2.wav'))
with open(os.path.join(d, 'fourmodes.wav'), 'wb') as f:
    f.write(b'RIFF' + struct.pack('<I', 36 + len(body)) + b'WAVEfmt ')
    f.write(struct.pack('<IHHIIHH', 16, 1, 1, 44100, 88200, 2, 16))
    f.write(b'data' + struct.pack('<I', len(body)))
    f.write(body)
print('fourmodes.wav: %.1f s' % (len(body) / 2 / 44100))
PY
rm -f "$OUT"/fourmodes-*.png
flog=$("$BIN" "$OUT/fourmodes.wav" --out "$OUT" 2>&1)
nfour=$(ls "$OUT"/fourmodes-*.png 2>/dev/null | wc -l | tr -d ' ')
got_modes=$(echo "$flog" | grep -c 'image ended (complete)')
if [ "$nfour" = "4" ] && [ "$got_modes" = "4" ] && \
   echo "$flog" | grep -q 'Robot 36' && echo "$flog" | grep -q 'Robot 72' && \
   echo "$flog" | grep -q 'Martin M1' && echo "$flog" | grep -q 'Martin M2'; then
    ok fourmodes 8/12/44/40 "4 pictures, auto-switched: $(ls "$OUT"/fourmodes-*.png | xargs -n1 basename | tr '\n' ' ')"
else
    bad fourmodes 8/12/44/40 "pictures $nfour, completed $got_modes :: $(echo "$flog" | grep -E 'VIS|ended' | tr '\n' '|')"
fi

# continuous reception: six pictures one after another, no gap at all, then the
# same with a 4 s pause between pictures (a sender changing mode by hand)
python3 - "$OUT" <<'PY'
import struct, sys, os
d = sys.argv[1]
def pcm(p):
    b = open(p, 'rb').read()
    i = b.find(b'data')
    n = struct.unpack('<I', b[i+4:i+8])[0]
    return b[i+8:i+8+n]
src = ['Robot36.wav', 'PD50.wav', 'MartinM2.wav', 'Robot72.wav', 'Robot36.wav', 'MartinM2.wav']
gap = b'\x00\x00' * (44100 * 4)
for name, g in (('sixn.wav', b''), ('sixg.wav', gap)):
    body = g.join(pcm(os.path.join(d, f)) for f in src)
    with open(os.path.join(d, name), 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(body)) + b'WAVEfmt ')
        f.write(struct.pack('<IHHIIHH', 16, 1, 1, 44100, 88200, 2, 16))
        f.write(b'data' + struct.pack('<I', len(body)))
        f.write(body)
PY
for v in sixn sixg; do
    rm -f "$OUT"/$v-*.png
    vlog=$("$BIN" "$OUT/$v.wav" --out "$OUT" --prefix "$v" 2>&1)
    n=$(ls "$OUT"/$v-*.png 2>/dev/null | wc -l | tr -d ' ')
    c=$(echo "$vlog" | grep -c 'image ended (complete)')
    if [ "$n" = "6" ] && [ "$c" = "6" ]; then
        ok "$v" "6 shots" "six pictures, $([ "$v" = "sixn" ] && echo 'no gap' || echo '4 s gaps')"
    else
        bad "$v" "6 shots" "pictures $n, complete $c :: $(echo "$vlog" | grep -E 'VIS|ended' | tr '\n' '|')"
    fi
done

# multiple files in one command line
rm -f "$OUT"/multi*.png
"$TX" "$OUT/testcard.ppm" "$OUT/m1.wav" --mode 8 >/dev/null 2>&1
"$TX" "$OUT/testcard.ppm" "$OUT/m2.wav" --mode 60 >/dev/null 2>&1
mlog=$("$BIN" "$OUT/m1.wav" "$OUT/m2.wav" --out "$OUT" --prefix multi 2>&1)
nmulti=$(ls "$OUT"/multi-*.png 2>/dev/null | wc -l | tr -d ' ')
if [ "$nmulti" = "2" ]; then ok multi "2 files" "2 pictures via --prefix"; else
    bad multi "2 files" "got $nmulti :: $(echo "$mlog" | tail -3 | tr '\n' '|')"; fi

# transmit -> receive round trip through the tool's own encoder (a picture in,
# a WAV out, decoded back), every mode.
echo
echo "== encode -> decode round trip"
IMAGE=$OUT/PD120-1.png
if [ ! -f "$IMAGE" ]; then
    bad encode "-" "no source picture ($IMAGE)"
else
    for entry in \
        "Robot36 8 320x240" "Robot72 12 320x240" "MartinM2 40 320x256" "MartinM1 44 320x256" \
        "ScottieS2 56 320x256" "ScottieS1 60 320x256" "ScottieDX 76 320x256" \
        "PD50 93 320x256" "PD90 99 320x256" "PD120 95 320x248" "PD160 98 256x200" \
        "PD180 96 320x248" "PD240 97 320x248" "PD290 94 400x308"; do
        set -- $entry
        nm=$1 vis=$2 want=$3
        wav=$OUT/rt-$nm.wav
        rm -f "$OUT"/rt-"$nm"-*.png
        if ! "$BIN" encode "$IMAGE" --mode "$vis" --out "$wav" >/dev/null 2>&1; then
            bad "enc $nm" "$vis" "encoder failed"
            continue
        fi
        dlog=$("$BIN" "$wav" --out "$OUT" --prefix "rt-$nm" 2>&1)
        png=$OUT/rt-$nm-1.png
        if [ ! -f "$png" ]; then
            bad "enc $nm" "$vis" "encoded but did not decode"
            continue
        fi
        got=$(pngsize "$png")
        if [ "$got" = "$want" ] && echo "$dlog" | grep -q 'image ended (complete)' && \
           echo "$dlog" | grep -q "VIS $vis "; then
            ok "enc $nm" "$vis" "$got round trip"
        else
            bad "enc $nm" "$vis" "want $want got $got :: $(echo "$dlog" | grep -E 'VIS|ended' | tr '\n' '|')"
        fi
        rm -f "$wav"
    done
fi

echo
echo "$pass passed, $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
