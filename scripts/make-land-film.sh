#!/usr/bin/env bash
#
# make-land-film.sh — 土地物件分鏡式行銷影片
#
# 以「分鏡表」驅動：每個鏡頭各自指定秒數、運鏡模式、關鍵字特效與字幕。
# 適合需要精確控時的段落式影片（鉤子 / 區位 / 規格 / 賣點 / 邀請 / 風險揭露）。
#
# 用法：
#   ./make-land-film.sh <素材資料夾> <分鏡表.txt> [輸出檔.mp4]
#
# 分鏡表格式（| 分隔，空欄位保留）：
#   檔名 | 秒數 | 模式 | 關鍵字 | 說明文字
#
#   模式：
#     kb            Ken Burns 緩慢推近／拉遠（預設，交錯進行）
#     still         靜止不運鏡（圖表、地圖、文件用，文字才不會晃）
#     count:N:單位   數字由 0 跳動計數到 N，後方接單位（用於面積、坪數）
#     stamp         關鍵字以印章方式落下並輕微回彈（用於使用分區、地目）
#     box:x:y:w:h   對該區域做框選高亮（比例值 0~1），用於謄本、地籍圖重點欄位
#
#   以 # 開頭為註解；空的關鍵字與說明代表該鏡頭不上字幕。
#
# 可調參數（環境變數）：
#   VOL=0.30  FADE_IN=3  FADE_OUT=4   音樂音量與淡入淡出
#   W=1920 H=1080                     輸出尺寸（直式用 W=1080 H=1920）
#   FPS=60  CRF=20  XFADE=1.0
#   BGM=<路徑>                         指定背景音樂
#   TITLE/SUBTITLE/ENDLINE1..3        片頭片尾字卡（設空字串則不加）
#
set -euo pipefail

SRC="${1:-}"
BOARD="${2:-}"
OUT="${3:-land-film.mp4}"

[[ -z "$SRC" || ! -d "$SRC" ]] && { echo "用法：$0 <素材資料夾> <分鏡表.txt> [輸出檔.mp4]" >&2; exit 1; }
[[ -z "$BOARD" || ! -f "$BOARD" ]] && { echo "找不到分鏡表：$BOARD" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "找不到 ffmpeg" >&2; exit 1; }
command -v python3 >/dev/null || { echo "找不到 python3" >&2; exit 1; }

XFADE="${XFADE:-1.0}"; VOL="${VOL:-0.30}"
FADE_IN="${FADE_IN:-3.0}"; FADE_OUT="${FADE_OUT:-4.0}"
FPS="${FPS:-60}"; CRF="${CRF:-20}"
W="${W:-1920}"; H="${H:-1080}"
ZMAX="${ZMAX:-1.15}"      # 一般鏡頭的運鏡幅度
ZSTILL="${ZSTILL:-1.05}"  # 圖表類的極輕微呼吸，避免畫面完全靜止而顯得卡住

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 字級與版面以短邊為基準，橫式直式共用同一套比例
BASE=$(( W < H ? W : H ))
KW_FS=$((BASE/15)); DS_FS=$((BASE/30)); BIG_FS=$((BASE/7))
X0=$((W*7/100))
Y_KW=$((H*73/100)); Y_LINE=$((H*73/100+KW_FS+10)); Y_DS=$((H*73/100+KW_FS+30))
# 直式畫面的暗罩要更晚開始，才不會蓋掉太多畫面
if (( H > W )); then GRAD_START="0.62"; else GRAD_START="0.45"; fi

FONT=""
for f in \
  "/System/Library/Fonts/PingFang.ttc" "/System/Library/Fonts/Supplemental/Songti.ttc" \
  "/System/Library/Fonts/STHeiti Medium.ttc" "/Library/Fonts/Microsoft/MSJhengHei.ttf" \
  "/c/Windows/Fonts/msjh.ttc" "C:/Windows/Fonts/msjh.ttc" \
  "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc" \
  "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc" ; do
  [[ -f "$f" ]] && { FONT="$f"; break; }
done
[[ -z "$FONT" ]] && { echo "找不到中文字型，無法產生字幕。" >&2; exit 1; }

esc() { printf '%s' "$1" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/:/\\\\:/g" -e "s/'/\\\\\\\\\\\\'/g" -e "s/%/\\\\%/g"; }
tw() { python3 -c "
import sys,unicodedata
print(round(sum(1.0 if unicodedata.east_asian_width(c) in ('W','F') else 0.55 for c in sys.argv[1]),3))" "$1"; }


# 由左掃出的線／框：drawbox 不支援逐幀表達式，改用分段接力
sweep() {  # <x> <y> <總寬> <高> <起> <迄> <掃出秒數> <色>
  local x0=$1 y=$2 tw=$3 hh=$4 st=$5 en=$6 dur=$7 col=$8 segs=10 i
  for i in $(seq 0 $((segs-1))); do
    python3 -c "
import sys
x0,tw,hh,st,dur,segs,i=$x0,$tw,$hh,$st,$dur,$segs,$i
sx=int(round(x0+i*tw/segs)); sw=int(round(tw/segs))+1
print(f\"drawbox=x={sx}:y=$y:w={sw}:h={hh}:color=$col:thickness=fill:enable='between(t,{round(st+i*dur/segs,3)},$en)',\", end='')
"
  done
}

# ── 讀分鏡表 ────────────────────────────────────────────────
FILES=(); SECS=(); MODES=(); KWS=(); DSS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "${line// }" || "$line" == \#* ]] && continue
  IFS='|' read -r f s m k d <<< "$line"
  f="$(echo "$f" | sed 's/^ *//;s/ *$//')"; s="$(echo "${s:-}" | tr -d ' ')"
  m="$(echo "${m:-}" | tr -d ' ')"
  k="$(echo "${k:-}" | sed 's/^ *//;s/ *$//')"; d="$(echo "${d:-}" | sed 's/^ *//;s/ *$//')"
  if   [[ -f "$SRC/$f" ]]; then FILES+=("$SRC/$f")
  elif [[ -f "$f"      ]]; then FILES+=("$f")
  elif [[ "$f" == CARD:* ]]; then FILES+=("$f")
  else echo "  ! 找不到素材：$f" >&2; exit 1
  fi
  SECS+=("${s:-5}"); MODES+=("${m:-kb}"); KWS+=("$k"); DSS+=("$d")
done < "$BOARD"

N=${#FILES[@]}
(( N == 0 )) && { echo "分鏡表是空的。" >&2; exit 1; }

# 字卡：分鏡表裡寫成 CARD:主標::副標::小字
for i in $(seq 0 $((N-1))); do
  [[ "${FILES[$i]}" != CARD:* ]] && continue
  body="${FILES[$i]#CARD:}"
  l1="${body%%::*}"; rest="${body#*::}"
  l2="${rest%%::*}"; l3=""
  [[ "$rest" == *"::"* ]] && l3="${rest#*::}"
  [[ "$l2" == "$rest" ]] && l2=""
  png="$WORK/card_$i.png"
  extra=""
  [[ -n "$l3" ]] && extra=",drawtext=fontfile='$FONT':text='$(esc "$l3")':fontcolor=0x9A968E:fontsize=$((BASE/40)):x=(w-text_w)/2:y=h/2+$((BASE/5)):line_spacing=$((BASE/60))"
  ffmpeg -y -loglevel error -f lavfi -i "color=c=0x101418:s=${W}x${H}" -frames:v 1 \
    -vf "drawtext=fontfile='$FONT':text='$(esc "$l1")':fontcolor=0xF2EFE9:fontsize=$((BASE/13)):x=(w-text_w)/2:y=(h-text_h)/2-$((BASE/18)),\
drawtext=fontfile='$FONT':text='$(esc "$l2")':fontcolor=0xB9A981:fontsize=$((BASE/28)):x=(w-text_w)/2:y=(h-text_h)/2+$((BASE/18)),\
drawbox=x=(iw-$((BASE/6)))/2:y=ih/2+$((BASE/75)):w=$((BASE/6)):h=2:color=0xB9A981@0.8:t=fill${extra}" "$png"
  FILES[$i]="$png"
done

# ── 時間軸：逐段累加，段落可各自不同長度 ────────────────────
START=(); acc=0
for i in $(seq 0 $((N-1))); do
  START+=("$acc")
  acc=$(python3 -c "print(round($acc + ${SECS[$i]} - $XFADE, 4))")
done
TOTAL=$(python3 -c "print(round($acc + $XFADE, 3))")
echo "▸ ${N} 個鏡頭，總長 ${TOTAL} 秒　輸出 ${W}x${H} @ ${FPS}fps"

BGM="${BGM:-}"
[[ -z "$BGM" ]] && BGM="$(find "$SRC" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.wav' \) | sort | head -1)"

# ── 畫面 ────────────────────────────────────────────────────
INPUTS=(); FILTER=""
BIGW=$((W*5/2)); BIGH=$((H*5/2))
MIDW=$((W*2)); MIDH=$((H*2))   # zoompan 的輸出尺寸，縮回 1080p 時跳動被平均掉
for i in $(seq 0 $((N-1))); do
  INPUTS+=(-loop 1 -framerate 1 -t 1 -i "${FILES[$i]}")
  zf=$(python3 -c "print(int(round(${SECS[$i]}*$FPS)))")
  mode="${MODES[$i]}"
  case "$mode" in
    still|count:*|box:*)
       # 圖表不做推近（文字會晃），但給極輕微的縮放讓畫面保持呼吸
       ZEXPR="z='1+(${ZSTILL}-1)*min(on/${zf},1)'" ;;
    *) if (( i % 2 == 0 )); then ZEXPR="z='1+(${ZMAX}-1)*min(on/${zf},1)'"
       else ZEXPR="z='${ZMAX}-(${ZMAX}-1)*min(on/${zf},1)'"; fi ;;
  esac
  FILTER+="[${i}:v]scale=480:270:force_original_aspect_ratio=increase,crop=480:270,gblur=sigma=10,scale=${BIGW}:${BIGH}[bg${i}];"
  FILTER+="[${i}:v]scale=${BIGW}:${BIGH}:force_original_aspect_ratio=decrease:flags=lanczos[fg${i}];"
  FILTER+="[bg${i}][fg${i}]overlay=(W-w)/2:(H-h)/2,setsar=1,"
  FILTER+="zoompan=${ZEXPR}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=${zf}:s=${MIDW}x${MIDH}:fps=${FPS},"
  FILTER+="scale=${W}:${H}:flags=lanczos,format=yuv420p,setsar=1[v${i}];"
done

PREV="[v0]"
for i in $(seq 1 $((N-1))); do
  off=$(python3 -c "print(round(${START[$i]}, 4))")
  FILTER+="${PREV}[v${i}]xfade=transition=fade:duration=${XFADE}:offset=${off}[x${i}];"
  PREV="[x${i}]"
done

# ── 字幕與關鍵字特效 ────────────────────────────────────────
ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=${W}x${H}" -frames:v 1 \
  -vf "format=yuva420p,geq=r=0:g=0:b=0:a='if(lt(Y,H*${GRAD_START}),0,255*0.88*pow((Y-H*${GRAD_START})/(H*(1-${GRAD_START})),1.0))'" \
  -pix_fmt rgba "$WORK/grad.png"
GRADIDX=$N
INPUTS+=(-loop 1 -t "$TOTAL" -i "$WORK/grad.png")

SUBS=""; CAP_FIRST=""; CAP_LAST=""
for i in $(seq 0 $((N-1))); do
  kw="${KWS[$i]}"; ds="${DSS[$i]}"; mode="${MODES[$i]}"
  [[ -z "$kw" && -z "$ds" ]] && continue
  S=$(python3 -c "print(round(${START[$i]} + $XFADE*0.95, 3))")
  E=$(python3 -c "print(round(${START[$i]} + ${SECS[$i]} - $XFADE*0.4, 3))")
  FA=0.45
  AL="if(lt(t,$S+$FA),(t-$S)/$FA,if(gt(t,$E-$FA),($E-t)/$FA,1))"
  EN="between(t,$S,$E)"
  [[ -z "$CAP_FIRST" ]] && CAP_FIRST="$S"
  CAP_LAST="$E"

  case "$mode" in
    count:*)
      # 數字由 0 跳動計數到目標值，單位固定在右側
      tgt="${mode#count:}"; unit="${tgt#*:}"; tgt="${tgt%%:*}"
      CD=1.6   # 計數秒數
      digits=${#tgt}
      numw=$(python3 -c "print(int(round($digits*0.62*$BIG_FS)))")
      SUBS+="drawtext=fontfile='$FONT':text='%{eif\\:trunc(min(max((t-$S)/$CD\\,0)\\,1)*${tgt})\\:d}':"
      SUBS+="fontcolor=0xF7E4B0:fontsize=${BIG_FS}:x=${X0}:y=$((Y_KW-BIG_FS-KW_FS/2)):"
      SUBS+="borderw=5:bordercolor=0x000000@0.6:alpha='${AL}':enable='${EN}',"
      SUBS+="drawtext=fontfile='$FONT':text='$(esc "$unit")':fontcolor=0xF7E4B0:fontsize=${KW_FS}:"
      SUBS+="x=$((X0+numw)):y=$((Y_KW-KW_FS-KW_FS/2)):borderw=4:bordercolor=0x000000@0.55:"
      SUBS+="alpha='${AL}':enable='${EN}',"
      kw=""   # 數字已取代關鍵字位置
      ;;
    stamp)
      # 印章式落下：由上方掉入並停住，帶邊框
      LW=$(python3 -c "print(int(round($(tw "$kw")*$KW_FS)))")
      PY="${Y_KW}-max(0,1-(t-$S)/0.45)*$((BASE/6))"
      SUBS+="drawtext=fontfile='$FONT':text='$(esc "$kw")':fontcolor=0xF7E4B0:fontsize=${KW_FS}:"
      SUBS+="x=${X0}:y='${PY}':borderw=4:bordercolor=0x000000@0.55:"
      SUBS+="alpha='${AL}':enable='${EN}',"
      BOXST=$(python3 -c "print(round($S+0.45,3))")
      SUBS+="drawbox=x=$((X0-KW_FS/3)):y=$((Y_KW-KW_FS/4)):w=$((LW+2*KW_FS/3)):h=$((KW_FS*3/2)):"
      SUBS+="color=0xC9A227@0.9:thickness=4:enable='between(t,${BOXST},${E})',"
      kw=""   # 印章已經畫過關鍵字
      ;;
    box:*)
      # 框選高亮：指定比例區域，框線由左上展開
      spec="${mode#box:}"; bx=${spec%%:*}; spec=${spec#*:}
      by=${spec%%:*}; spec=${spec#*:}; bw=${spec%%:*}; bh=${spec#*:}
      PX=$(python3 -c "print(int($W*$bx))"); PY2=$(python3 -c "print(int($H*$by))")
      PW=$(python3 -c "print(int($W*$bw))"); PH=$(python3 -c "print(int($H*$bh))")
      SUBS+="$(sweep "$PX" "$PY2" "$PW" 5 "$S" "$E" 0.5 "0xC9A227@0.95")"
      SUBS+="$(sweep "$PX" "$((PY2+PH))" "$PW" 5 "$S" "$E" 0.5 "0xC9A227@0.95")"
      ;;
  esac

  if [[ -n "$kw" ]]; then
    LW=$(python3 -c "print(int(round($(tw "$kw")*$KW_FS)))")
    SUBS+="drawtext=fontfile='$FONT':text='$(esc "$kw")':fontcolor=0xF7E4B0:fontsize=${KW_FS}:"
    SUBS+="x=${X0}:y=${Y_KW}:borderw=4:bordercolor=0x000000@0.55:shadowx=0:shadowy=3:"
    SUBS+="shadowcolor=0x000000@0.5:alpha='${AL}':enable='${EN}',"
    SUBS+="$(sweep "$X0" "$Y_LINE" "$LW" 4 "$S" "$E" 0.55 "0xC9A227@0.95")"
  fi
  if [[ -n "$ds" ]]; then
    SUBS+="drawtext=fontfile='$FONT':text='$(esc "$ds")':fontcolor=0xFFFFFF@0.9:fontsize=${DS_FS}:"
    SUBS+="x=${X0}:y=${Y_DS}:borderw=3:bordercolor=0x000000@0.5:alpha='${AL}':enable='${EN}',"
  fi
done

GIN=$(python3 -c "print(max(0,round(${CAP_FIRST:-0}-0.55,3)))")
GOUT=$(python3 -c "print(round(${CAP_LAST:-0}+0.05,3))")
FILTER+="[${GRADIDX}:v]format=yuva420p,fade=t=in:st=${GIN}:d=0.6:alpha=1,fade=t=out:st=${GOUT}:d=0.6:alpha=1[gradf];"
FILTER+="${PREV}[gradf]overlay=0:0[grd];"
FOST=$(python3 -c "print(round($TOTAL-1.5,3))")
FILTER+="[grd]${SUBS}fade=t=in:st=0:d=1.2,fade=t=out:st=${FOST}:d=1.5[vout]"

# ── 音訊：不夠長時自我交叉淡接，避免循環接縫 ────────────────
if [[ -n "$BGM" ]]; then
  AIDX=$((N+1))
  BGMLEN=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BGM")
  NEED=$(python3 -c "print(1 if $BGMLEN < $TOTAL else 0)")
  if (( NEED == 1 )); then
    echo "▸ 音樂 ${BGMLEN%.*} 秒短於片長，以 5 秒交叉淡接自我延長"
    INPUTS+=(-i "$BGM" -i "$BGM")
    FILTER+=";[${AIDX}:a][$((AIDX+1)):a]acrossfade=d=5:c1=tri:c2=tri[abase];"
    ASRC="[abase]"
  else
    INPUTS+=(-i "$BGM")
    FILTER+=";"
    ASRC="[${AIDX}:a]"
  fi
  AFO=$(python3 -c "print(round($TOTAL-$FADE_OUT,3))")
  FILTER+="${ASRC}atrim=0:${TOTAL},asetpts=N/SR/TB,volume=${VOL},"
  FILTER+="afade=t=in:st=0:d=${FADE_IN},afade=t=out:st=${AFO}:d=${FADE_OUT}[aout]"
  MAP=(-map "[vout]" -map "[aout]" -c:a aac -b:a 192k)
else
  MAP=(-map "[vout]" -an)
fi

if [[ -n "${DEBUG_FILTER:-}" ]]; then printf '%s\n' "$FILTER" | tr ';' '\n'; exit 0; fi

echo "▸ 編碼中…"
ffmpeg -y -hide_banner -loglevel warning -stats \
  "${INPUTS[@]}" -filter_complex "$FILTER" "${MAP[@]}" \
  -c:v libx264 -preset medium -crf "$CRF" -pix_fmt yuv420p -r "$FPS" \
  -movflags +faststart -t "$TOTAL" "$OUT"
echo "✓ $OUT"
ls -lh "$OUT" | awk '{print "  ",$5}'
