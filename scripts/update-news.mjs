// 每兩週自動更新首頁「南臺灣不動產要聞」列表（頭條不動）
// 資料來源：Google News RSS，限定不動產媒體 + 台南/高雄/南科 關鍵字
// 執行：node scripts/update-news.mjs

import { readFile, writeFile } from 'node:fs/promises';

const SITES = [
  'estate.ltn.com.tw',
  'house.ettoday.net',
  'house.chinatimes.com',
  'udn.com',
  'money.udn.com',
  'ctee.com.tw',
  'housefeel.com.tw',
];

// 標題須含至少一個地區/題材關鍵字
const MUST = ['台南', '臺南', '高雄', '南科', '楠梓', '橋頭', '岡山', '永康', '善化', '新市', '仁德', '歸仁', '安南', '白埔', '沙崙', '麻豆'];

// 且須含至少一個不動產題材關鍵字
const TOPIC = ['土地', '建地', '工業區', '產業園區', '廠房', '重劃', '標售', '地上權', '建照', '都市計畫', '房市', '房價', '實價', '招商', '設廠', '擴廠', '交流道', '捷運', '園區'];

// 排除
const BLOCK = ['詐騙', '命案', '火警', '抽獎', '優惠', '團購', '限時', '直播', '爆料'];

const MAX = 8;

const FEED = 'https://news.google.com/rss/search?q=' +
  encodeURIComponent('(' + SITES.map(s => `site:${s}`).join(' OR ') + ') (台南 OR 高雄 OR 南科) (土地 OR 房市 OR 產業園區 OR 廠房)') +
  '&hl=zh-TW&gl=TW&ceid=TW:zh-Hant';

const LABEL = {
  'estate.ltn.com.tw': '自由時報地產天下',
  'house.ettoday.net': 'ETtoday 房產雲',
  'house.chinatimes.com': '中時房產',
  'udn.com': '聯合新聞網',
  'money.udn.com': '經濟日報',
  'ctee.com.tw': '工商時報',
  'housefeel.com.tw': 'HouseFeel 房感',
};

const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function decode(s) {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(+d))
    .replace(/&#x([0-9a-f]+);/gi, (_, x) => String.fromCharCode(parseInt(x, 16)))
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&')
    .trim();
}

function parseItems(xml) {
  const out = [];
  for (const m of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const b = m[1];
    const pick = tag => {
      const r = b.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`));
      return r ? decode(r[1]) : '';
    };
    let title = pick('title');
    const link = pick('link');
    const pubDate = pick('pubDate');
    let source = pick('source');
    const dash = title.lastIndexOf(' - ');
    if (dash > 15) { if (!source) source = title.slice(dash + 3); title = title.slice(0, dash); }
    if (!title || !link) continue;
    out.push({ title, link, pubDate, source });
  }
  return out;
}

function siteOf(it) {
  for (const s of SITES) if (it.link.includes(s)) return s;
  // Google News 有時給轉址網址，退回用 source 名稱比對
  for (const [s, label] of Object.entries(LABEL)) {
    if ((it.source || '').includes(label.replace(/ .*/, ''))) return s;
  }
  return null;
}

function ymd(pubDate) {
  const d = new Date(pubDate);
  if (isNaN(d)) return '';
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}.${p(d.getMonth() + 1)}.${p(d.getDate())}`;
}

const main = async () => {
  const res = await fetch(FEED, { headers: { 'user-agent': 'yiding-news-bot' } });
  if (!res.ok) throw new Error(`RSS ${res.status}`);
  const items = parseItems(await res.text());

  const seenTitle = new Set();
  const seenLink = new Set();
  const picked = [];
  for (const it of items) {
    const site = siteOf(it);
    if (!site) continue;
    if (!MUST.some(k => it.title.includes(k))) continue;
    if (!TOPIC.some(k => it.title.includes(k))) continue;
    if (BLOCK.some(k => it.title.includes(k))) continue;
    if (seenTitle.has(it.title) || seenLink.has(it.link)) continue;   // 一則新聞一個連結
    seenTitle.add(it.title);
    seenLink.add(it.link);
    picked.push({ ...it, site, date: ymd(it.pubDate) });
    if (picked.length >= MAX) break;
  }

  if (picked.length < MAX) {
    console.log(`只找到 ${picked.length} 則合格新聞，未達 ${MAX} 則門檻，維持原內容不變。`);
    return;
  }

  const rows = picked.map((p, i) => `        <a class="news-item" href="${esc(p.link)}" target="_blank" rel="noopener">
          <span class="news-num">${i + 1}</span>
          <div>
            <h4>${esc(p.title)}</h4>
            <p class="news-meta">${esc(p.date)} · ${esc(LABEL[p.site] || p.site)}</p>
          </div>
        </a>
`).join('');

  let html = await readFile('index.html', 'utf8');
  const S = '<!-- AUTO:NEWS:START -->';
  const E = '<!-- AUTO:NEWS:END -->';
  const i = html.indexOf(S), j = html.indexOf(E);
  if (i < 0 || j < 0) throw new Error('找不到 AUTO:NEWS 標記');
  html = html.slice(0, i + S.length) + `\n      <div class="news-rank">\n${rows}      </div>\n      ` + html.slice(j);
  await writeFile('index.html', html);

  console.log(`更新完成：${picked.length} 則要聞（頭條未變動）`);
  picked.forEach((p, k) => console.log(`  ${k + 1}. [${p.date}] ${p.title} (${p.site})`));
};

main().catch(err => { console.error(err.message); process.exit(1); });
