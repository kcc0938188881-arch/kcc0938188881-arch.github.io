#!/usr/bin/env bash
#
# make-land-video.sh — 土地物件照片剪輯成行銷影片
#   Ken Burns 運鏡 ‧ 交叉溶接 ‧ 行銷字幕（關鍵字聚焦特效）‧ 背景音樂淡入淡出
#
# 用法：
#   ./make-land-video.sh <素材資料夾> [輸出檔.mp4]
#
# 範例（精準做成 40 秒）：
#   TARGET=40 ./make-land-video.sh ~/Downloads/大內頭社段 AVI142.mp4
#
# 素材資料夾規則：
#   - 畫面：資料夾內（含子資料夾）所有 .jpg/.jpeg/.png，依檔名排序
#   - 音樂：資料夾內第一個 .mp3/.m4a/.wav；或用 BGM=<路徑> 指定
#   - 順序：放 shotlist.txt，一行一個檔名（相對路徑），照該順序播
#   - 字幕：放 captions.txt，一行一句 `關鍵字|說明文字`，依序套到每張照片
#           空行 = 該張不上字幕；# 開頭 = 註解
#
set -euo pipefail

SRC="${1:-}"
OUT="${2:-land-video.mp4}"

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "用法：$0 <素材資料夾> [輸出檔.mp4]" >&2
  exit 1
fi

command -v ffmpeg >/dev/null || { echo "找不到 ffmpeg。macOS 請先執行：brew install ffmpeg" >&2; exit 1; }
command -v python3 >/dev/null || { echo "找不到 python3。" >&2; exit 1; }

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
ENDLINE3="${ENDLINE3:-本影片資訊僅供參考，實際以政府公告及現地查核為準}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. 收集照片 ──────────────────────────────────────────────
PHOTOS=()
if [[ -f "$SRC/shotlist.txt" ]]; then
  echo "▸ 依 shotlist.txt 指定順序排列"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if   [[ -f "$SRC/$line" ]]; then PHOTOS+=("$SRC/$line")
    elif [[ -f "$line"      ]]; then PHOTOS+=("$line")
    else echo "  ! 找不到：$line（略過）" >&2
    fi
  done < "$SRC/shotlist.txt"
else
  while IFS= read -r f; do PHOTOS+=("$f"); done < <(
    find "$SRC" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort
  )
fi
[[ ${#PHOTOS[@]} -eq 0 ]] && { echo "資料夾裡找不到任何照片。" >&2; exit 1; }
NPHOTO=${#PHOTOS[@]}
echo "▸ 找到 ${NPHOTO} 張照片"

# ── 2. 讀字幕 ────────────────────────────────────────────────
CAP_KW=(); CAP_DESC=()
if [[ -f "$SRC/captions.txt" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" == \#* ]] && continue
    CAP_KW+=("${line%%|*}")
    [[ "$line" == *"|"* ]] && CAP_DESC+=("${line#*|}") || CAP_DESC+=("")
  done < "$SRC/captions.txt"
  echo "▸ 讀到 ${#CAP_KW[@]} 句字幕"
fi

# ── 3. 找背景音樂 ────────────────────────────────────────────
BGM="${BGM:-}"
[[ -z "$BGM" ]] && BGM="$(find "$SRC" -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' \) | sort | head -1)"
[[ -n "$BGM" ]] && echo "▸ 背景音樂：$(basename "$BGM")" || echo "▸ 沒有背景音樂，輸出無聲影片"

# ── 4. 中文字型偵測（找不到就跳過所有文字，影片照樣輸出）────
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
[[ -z "$FONT" ]] && echo "▸ 未偵測到中文字型，略過字卡與字幕"

esc() { printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/:/\\\\:/g" -e "s/'/\\\\\\\\\\\\'/g" -e "s/%/\\\\%/g"; }

# 估算一段中文／英數混排文字的顯示寬度（單位：字級倍數）
textwidth() { python3 -c "
import sys,unicodedata
s=sys.argv[1]; w=0.0
for c in s:
    w += 1.0 if unicodedata.east_asian_width(c) in ('W','F') else 0.55
print(round(w,3))" "$1"; }

# ── 5. 片頭／片尾字卡 ────────────────────────────────────────
make_card() {  # <輸出png> <主標> <副標> [第三行小字]
  local out="$1" l1="$2" l2="$3" l3="${4:-}"
  local df="fontfile='$FONT'" extra=""
  [[ -n "$l3" ]] && extra=",drawtext=${df}:text='$(esc "$l3")':fontcolor=0x8C8880:fontsize=$((H/46)):x=(w-text_w)/2:y=h-$((H/9))"
  ffmpeg -y -loglevel error -f lavfi -i "color=c=0x101418:s=${W}x${H}" -frames:v 1 \
    -vf "drawtext=${df}:text='$(esc "$l1")':fontcolor=0xF2EFE9:fontsize=$((H/13)):x=(w-text_w)/2:y=(h-text_h)/2-$((H/18)),\
drawtext=${df}:text='$(esc "$l2")':fontcolor=0xB9A981:fontsize=$((H/28)):x=(w-text_w)/2:y=(h-text_h)/2+$((H/18)),\
drawbox=x=(iw-$((W/6)))/2:y=ih/2+$((H/75)):w=$((W/6)):h=2:color=0xB9A981@0.8:t=fill${extra}" \
    "$out"
}

HEAD_CARD=0
if [[ -n "$FONT" && -n "$TITLE" ]]; then
  make_card "$WORK/00_title.png" "$TITLE" "$SUBTITLE"
  PHOTOS=("$WORK/00_title.png" "${PHOTOS[@]}")
  HEAD_CARD=1
fi
if [[ -n "$FONT" && -n "$ENDLINE1" ]]; then
  make_card "$WORK/zz_end.png" "$ENDLINE1" "$ENDLINE2" "$ENDLINE3"
  PHOTOS+=("$WORK/zz_end.png")
fi
N=${#PHOTOS[@]}

# ── 6. 每張秒數：給了 TARGET 就反推，命中指定總長 ────────────
if [[ -n "${TARGET:-}" ]]; then
  DUR=$(python3 -c "print(round(($TARGET+($N-1)*$XFADE)/$N, 4))")
  echo "▸ 目標總長 ${TARGET} 秒 → 每張 ${DUR} 秒"
else
  DUR="${DUR:-4.5}"
fi
TOTAL=$(python3 -c "print(round($N*$DUR-($N-1)*$XFADE, 3))")
echo "▸ 共 ${N} 段，影片長度約 ${TOTAL} 秒"

# ── 7. 畫面：模糊底滿版 → Ken Burns → 交叉溶接 ───────────────
INPUTS=(); FILTER=""
ZFRAMES=$(python3 -c "print(int(round($DUR*$FPS)))")
BIGW=$((W*2)); BIGH=$((H*2))

for i in $(seq 0 $((N-1))); do
  INPUTS+=(-loop 1 -t "$DUR" -i "${PHOTOS[$i]}")
  if (( i % 2 == 0 )); then
    ZEXPR="z='min(zoom+0.00045,1.10)'"                              # 緩推近
  else
    ZEXPR="z='if(lte(zoom,1.0),1.10,max(1.001,zoom-0.00045))'"      # 緩拉遠
  fi
  FILTER+="[${i}:v]scale=${BIGW}:${BIGH}:force_original_aspect_ratio=increase,crop=${BIGW}:${BIGH},gblur=sigma=32[bg${i}];"
  FILTER+="[${i}:v]scale=${BIGW}:${BIGH}:force_original_aspect_ratio=decrease[fg${i}];"
  FILTER+="[bg${i}][fg${i}]overlay=(W-w)/2:(H-h)/2,setsar=1,"
  FILTER+="zoompan=${ZEXPR}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=${ZFRAMES}:s=${W}x${H}:fps=${FPS},"
  FILTER+="format=yuv420p,setsar=1[v${i}];"
done

if (( N == 1 )); then
  PREV="[v0]"
else
  PREV="[v0]"
  for i in $(seq 1 $((N-1))); do
    OFFSET=$(python3 -c "print(round(($DUR-$XFADE)*$i, 3))")
    FILTER+="${PREV}[v${i}]xfade=transition=fade:duration=${XFADE}:offset=${OFFSET}[x${i}];"
    PREV="[x${i}]"
  done
fi

# ── 8. 行銷字幕層：底部漸層暗帶 + 關鍵字 + 說明 + 金線掃出 ───
SUBS=""; GRAD_OVERLAY=""
if [[ -n "$FONT" && ${#CAP_KW[@]} -gt 0 ]]; then
  KW_FS=$((H/15))          # 關鍵字字級
  DS_FS=$((H/30))          # 說明字級
  X0=$((W*7/100))          # 左邊界
  Y_KW=$((H*73/100))
  Y_LINE=$((H*73/100+KW_FS+10))
  Y_DS=$((H*73/100+KW_FS+30))

  # 底部平滑漸層暗罩（預先算一張 PNG，避免逐幀運算）
  # 確保白字疊在亮空拍照上仍然清楚，且沒有階梯硬邊
  ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=${W}x${H}" -frames:v 1 \
    -vf "format=yuva420p,geq=r=0:g=0:b=0:a='if(lt(Y,H*0.45),0,255*0.88*pow((Y-H*0.45)/(H*0.55),1.0))'" \
    -pix_fmt rgba "$WORK/grad.png"
  GRADIDX=$N
  INPUTS+=(-loop 1 -t "$TOTAL" -i "$WORK/grad.png")
  GRAD_OVERLAY="[${GRADIDX}:v]"

  for k in $(seq 0 $(( ${#CAP_KW[@]} - 1 ))); do
    kw="${CAP_KW[$k]}"; ds="${CAP_DESC[$k]}"
    [[ -z "$kw" && -z "$ds" ]] && continue
    seg=$(( k + HEAD_CARD ))                       # 對應到第幾段畫面
    (( seg > N-1 )) && break
    # 等轉場幾乎收完才進字幕，收在下一次轉場中途淡出
    S=$(python3 -c "print(round(($DUR-$XFADE)*$seg + $XFADE*0.95, 3))")
    E=$(python3 -c "print(round(($DUR-$XFADE)*$seg + $XFADE*0.95 + $DUR - $XFADE*1.35, 3))")
    FA=0.45                                        # 字幕淡入／淡出秒數
    AL="if(lt(t,$S+$FA),(t-$S)/$FA,if(gt(t,$E-$FA),($E-t)/$FA,1))"
    EN="between(t,$S,$E)"

    if [[ -n "$kw" ]]; then
      LW=$(python3 -c "print(int(round($(textwidth "$kw")*$KW_FS)))")
      SUBS+="drawtext=fontfile='$FONT':text='$(esc "$kw")':fontcolor=0xF7E4B0:fontsize=${KW_FS}:x=${X0}:y=${Y_KW}"
      SUBS+=":borderw=4:bordercolor=0x000000@0.55:shadowx=0:shadowy=3:shadowcolor=0x000000@0.5"
      SUBS+=":alpha='${AL}':enable='${EN}',"
      # 金線在關鍵字下方 0.55 秒由左掃出，視覺聚焦
      SUBS+="drawbox=x=${X0}:y=${Y_LINE}:w='min(max((t-$S)/0.55,0),1)*${LW}':h=4:color=0xC9A227@0.95:t=fill:enable='${EN}',"
    fi
    if [[ -n "$ds" ]]; then
      SUBS+="drawtext=fontfile='$FONT':text='$(esc "$ds")':fontcolor=0xFFFFFF@0.9:fontsize=${DS_FS}:x=${X0}:y=${Y_DS}"
      SUBS+=":borderw=3:bordercolor=0x000000@0.5:alpha='${AL}':enable='${EN}',"
    fi
  done
fi

if [[ -n "$GRAD_OVERLAY" ]]; then
  FILTER+="${PREV}${GRAD_OVERLAY}overlay=0:0[grd];"
  PREV="[grd]"
fi

FADE_OUT_ST=$(python3 -c "print(round($TOTAL-1.5,3))")
FILTER+="${PREV}${SUBS}fade=t=in:st=0:d=1.2,fade=t=out:st=${FADE_OUT_ST}:d=1.5[vout]"

# ── 9. 音訊：音量偏小 + 片頭漸大 + 片尾漸小 ──────────────────
if [[ -n "$BGM" ]]; then
  AIDX=$N
  [[ -n "$GRAD_OVERLAY" ]] && AIDX=$((N+1))
  INPUTS+=(-stream_loop -1 -i "$BGM")      # 音樂不夠長自動循環
  AF_OUT_ST=$(python3 -c "print(round($TOTAL-$FADE_OUT,3))")
  FILTER+=";[${AIDX}:a]atrim=0:${TOTAL},asetpts=N/SR/TB,volume=${VOL},"
  FILTER+="afade=t=in:st=0:d=${FADE_IN},afade=t=out:st=${AF_OUT_ST}:d=${FADE_OUT}[aout]"
  MAP=(-map "[vout]" -map "[aout]" -c:a aac -b:a 192k)
else
  MAP=(-map "[vout]" -an)
fi

# ── 10. 輸出 ────────────────────────────────────────────────
if [[ -n "${DEBUG_FILTER:-}" ]]; then
  echo "--- grad.png ---"; ls -l "$WORK/grad.png" 2>&1
  echo "--- inputs (last 6) ---"; echo "${INPUTS[@]: -6}"
  echo "--- overlay segment ---"; printf '%s\n' "$FILTER" | tr ';' '\n' | grep -n "overlay=0:0" || echo "（沒有 overlay=0:0）"
  exit 0
fi
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
