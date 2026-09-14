#!/usr/bin/env bash
#
# make-land-video.sh — 土地物件照片剪輯成影片（含 Ken Burns 運鏡、交叉溶接、背景音樂淡入淡出）
#
# 用法：
#   ./make-land-video.sh <素材資料夾> [輸出檔.mp4]
#
# 範例：
#   ./make-land-video.sh ~/Downloads/AVI142-頭社段21-8-志誠 AVI142.mp4
#
# 素材資料夾規則：
#   - 影片畫面：資料夾內（含子資料夾）所有 .jpg/.jpeg/.png，依檔名排序
#   - 背景音樂：資料夾內第一個 .mp3/.m4a/.wav；或用 BGM 環境變數指定路徑
#   - 想自訂播放順序：在資料夾內放一個 shotlist.txt，一行一個檔名（相對路徑），照該順序播
#
# 可調參數（用環境變數覆寫）：
#   DUR=4.5        每張照片停留秒數
#   XFADE=1.0      交叉溶接秒數
#   VOL=0.30       音樂音量倍率（0.30 約 -10dB，適中偏小）
#   FADE_IN=3.0    片頭音量漸大秒數
#   FADE_OUT=4.0   片尾音量漸小秒數
#   TITLE / SUBTITLE / ENDLINE1 / ENDLINE2   片頭片尾字卡文字（設為空字串即不加字卡）
#   FPS=30  W=1920  H=1080
#
set -euo pipefail

SRC="${1:-}"
OUT="${2:-land-video.mp4}"

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "用法：$0 <素材資料夾> [輸出檔.mp4]" >&2
  exit 1
fi

command -v ffmpeg >/dev/null || { echo "找不到 ffmpeg。macOS 請先執行：brew install ffmpeg" >&2; exit 1; }

DUR="${DUR:-4.5}"
XFADE="${XFADE:-1.0}"
VOL="${VOL:-0.30}"
FADE_IN="${FADE_IN:-3.0}"
FADE_OUT="${FADE_OUT:-4.0}"
FPS="${FPS:-30}"
W="${W:-1920}"
H="${H:-1080}"

TITLE="${TITLE:-台南．大內區 頭社段}"
SUBTITLE="${SUBTITLE:-山坡地保育區農牧用地　約 22,453 坪}"
ENDLINE1="${ENDLINE1:-義鼎不動產}"
ENDLINE2="${ENDLINE2:-案件編號 AVI142}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. 收集照片 ──────────────────────────────────────────────
PHOTOS=()
if [[ -f "$SRC/shotlist.txt" ]]; then
  echo "▸ 依 shotlist.txt 指定順序排列"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ -f "$SRC/$line" ]]; then PHOTOS+=("$SRC/$line")
    elif [[ -f "$line" ]]; then PHOTOS+=("$line")
    else echo "  ! 找不到：$line（略過）" >&2
    fi
  done < "$SRC/shotlist.txt"
else
  while IFS= read -r f; do PHOTOS+=("$f"); done < <(
    find "$SRC" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort
  )
fi

[[ ${#PHOTOS[@]} -eq 0 ]] && { echo "資料夾裡找不到任何照片。" >&2; exit 1; }
echo "▸ 找到 ${#PHOTOS[@]} 張照片"

# ── 2. 找背景音樂 ────────────────────────────────────────────
BGM="${BGM:-}"
if [[ -z "$BGM" ]]; then
  BGM="$(find "$SRC" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' \) | sort | head -1)"
fi
if [[ -n "$BGM" ]]; then
  echo "▸ 背景音樂：$(basename "$BGM")"
else
  echo "▸ 沒有背景音樂，輸出無聲影片"
fi

# ── 3. 中文字型偵測（找不到就跳過字卡，影片照常輸出）────────
FONT=""
for f in \
  "/System/Library/Fonts/PingFang.ttc" \
  "/System/Library/Fonts/Supplemental/Songti.ttc" \
  "/System/Library/Fonts/STHeiti Medium.ttc" \
  "/Library/Fonts/Microsoft/MSJhengHei.ttf" \
  "/c/Windows/Fonts/msjh.ttc" \
  "C:/Windows/Fonts/msjh.ttc" \
  "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc" \
  "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc" ; do
  [[ -f "$f" ]] && { FONT="$f"; break; }
done

esc() { printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/:/\\\\:/g" -e "s/'/\\\\\\\\\\\\'/g" -e "s/%/\\\\%/g"; }

make_card() {  # make_card <輸出png> <主標> <副標>
  local out="$1" l1="$2" l2="$3"
  local df="fontfile='$FONT'"
  ffmpeg -y -loglevel error -f lavfi -i "color=c=0x101418:s=${W}x${H}" -frames:v 1 \
    -vf "drawtext=${df}:text='$(esc "$l1")':fontcolor=0xF2EFE9:fontsize=$((H/13)):x=(w-text_w)/2:y=(h-text_h)/2-$((H/18)),\
drawtext=${df}:text='$(esc "$l2")':fontcolor=0xB9A981:fontsize=$((H/28)):x=(w-text_w)/2:y=(h-text_h)/2+$((H/18)),\
drawbox=x=(iw-$((W/6)))/2:y=ih/2+$((H/75)):w=$((W/6)):h=2:color=0xB9A981@0.8:t=fill" \
    "$out"
}

CARDS_ADDED=0
if [[ -n "$FONT" && -n "$TITLE" ]]; then
  make_card "$WORK/00_title.png" "$TITLE" "$SUBTITLE"
  PHOTOS=("$WORK/00_title.png" "${PHOTOS[@]}")
  CARDS_ADDED=1
fi
if [[ -n "$FONT" && -n "$ENDLINE1" ]]; then
  make_card "$WORK/zz_end.png" "$ENDLINE1" "$ENDLINE2"
  PHOTOS+=("$WORK/zz_end.png")
  CARDS_ADDED=1
fi
[[ -z "$FONT" ]] && echo "▸ 未偵測到中文字型，略過片頭／片尾字卡"
[[ "$CARDS_ADDED" == 1 ]] && echo "▸ 已加入片頭／片尾字卡"

N=${#PHOTOS[@]}

# ── 4. 組 filter_complex ────────────────────────────────────
# 每張：模糊底 + 置中滿版 →（4K 中介）→ zoompan 緩推／緩拉 → 1080p
INPUTS=()
FILTER=""
ZFRAMES=$(python3 -c "print(int(round($DUR*$FPS)))")
BIGW=$((W*2)); BIGH=$((H*2))

for i in $(seq 0 $((N-1))); do
  INPUTS+=(-loop 1 -t "$DUR" -i "${PHOTOS[$i]}")
  if (( i % 2 == 0 )); then
    ZEXPR="z='min(zoom+0.00045,1.10)'"            # 緩推近
  else
    ZEXPR="z='if(lte(zoom,1.0),1.10,max(1.001,zoom-0.00045))'"  # 緩拉遠
  fi
  FILTER+="[${i}:v]scale=${BIGW}:${BIGH}:force_original_aspect_ratio=increase,crop=${BIGW}:${BIGH},gblur=sigma=32[bg${i}];"
  FILTER+="[${i}:v]scale=${BIGW}:${BIGH}:force_original_aspect_ratio=decrease[fg${i}];"
  FILTER+="[bg${i}][fg${i}]overlay=(W-w)/2:(H-h)/2,setsar=1,"
  FILTER+="zoompan=${ZEXPR}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=${ZFRAMES}:s=${W}x${H}:fps=${FPS},"
  FILTER+="format=yuv420p,setsar=1[v${i}];"
done

if (( N == 1 )); then
  VLAST="[v0]"
else
  PREV="[v0]"
  for i in $(seq 1 $((N-1))); do
    OFFSET=$(python3 -c "print(round(($DUR-$XFADE)*$i, 3))")
    LBL="[x${i}]"
    FILTER+="${PREV}[v${i}]xfade=transition=fade:duration=${XFADE}:offset=${OFFSET}${LBL};"
    PREV="$LBL"
  done
  VLAST="$PREV"
fi

TOTAL=$(python3 -c "print(round($N*$DUR-($N-1)*$XFADE, 3))")
echo "▸ 影片長度約 ${TOTAL} 秒"

# 畫面首尾黑場
FILTER+="${VLAST}fade=t=in:st=0:d=1.2,fade=t=out:st=$(python3 -c "print(round($TOTAL-1.5,3))"):d=1.5[vout]"

# ── 5. 音訊：音量偏小 + 片頭漸大 + 片尾漸小 ──────────────────
if [[ -n "$BGM" ]]; then
  AIDX=$N
  INPUTS+=(-stream_loop -1 -i "$BGM")   # 音樂不夠長自動循環
  AFADE_OUT_ST=$(python3 -c "print(round($TOTAL-$FADE_OUT,3))")
  FILTER+=";[${AIDX}:a]atrim=0:${TOTAL},asetpts=N/SR/TB,volume=${VOL},"
  FILTER+="afade=t=in:st=0:d=${FADE_IN},afade=t=out:st=${AFADE_OUT_ST}:d=${FADE_OUT}[aout]"
  MAP=(-map "[vout]" -map "[aout]" -c:a aac -b:a 192k)
else
  MAP=(-map "[vout]" -an)
fi

# ── 6. 輸出 ─────────────────────────────────────────────────
echo "▸ 開始編碼…"
ffmpeg -y -hide_banner -loglevel warning -stats \
  "${INPUTS[@]}" \
  -filter_complex "$FILTER" \
  "${MAP[@]}" \
  -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r "$FPS" \
  -movflags +faststart -t "$TOTAL" \
  "$OUT"

echo "✓ 完成：$OUT"
ls -lh "$OUT"
