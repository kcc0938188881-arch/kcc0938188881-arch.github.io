// 每月自動更新「建築美學」文章
// 資料來源：Google News RSS（限定建築/設計媒體，關鍵字過濾）
// 執行：node scripts/update-articles.mjs

import { readFile, writeFile } from 'node:fs/promises';

// 只從這些媒體取用
const SITES = [
  'mottimes.com',
  'designwant.com',
  'archdaily.com',
  'la-vie.com.tw',
  'shoppingdesign.com.tw',
  'gooddesign.org.tw',
];

// 標題須含至少一個關鍵字
const KEYWORDS = ['建築', '設計師', '美術館', '空間', '事務所', '普立茲克', '清水模', '建案', '地標', '展覽', '建築師'];

// 標題含這些字就排除（廣告、抽獎、業配）
const BLOCK = ['抽獎', '折扣', '優惠', '團購', '開箱推薦', '促銷', '限時', '免費送', '好康'];

const MAX_INDEX = 4;   // 首頁卡片數
const MAX_LIST = 8;    // 文章頁列數

const FEED = 'https://news.google.com/rss/search?q=' +
  encodeURIComponent(SITES.map(s => `site:${s}`).join(' OR ')) +
  '&hl=zh-TW&gl=TW&ceid=TW:zh-Hant';

const SOURCE_LABEL = {
  'mottimes.com': 'MOT TIMES 明日誌',
  'designwant.com': '設計王 DesignWant',
  'archdaily.com': 'ArchDaily',
  'la-vie.com.tw': 'La Vie',
  'shoppingdesign.com.tw': 'Shopping Design',
  'gooddesign.org.tw': '台灣設計研究院',
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
    const desc = pick('description').replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    // Google News 標題結尾常帶「 - 媒體名」，切掉
    const dash = title.lastIndexOf(' - ');
    let source = pick('source');
    if (dash > 20) { if (!source) source = title.slice(dash + 3); title = title.slice(0, dash); }
    if (!title || !link) continue;
    out.push({ title, link, pubDate, desc, source });
  }
  return out;
}

function siteOf(item) {
  for (const s of SITES) {
    if (item.link.includes(s) || (item.source || '').toLowerCase().includes(s.split('.')[0])) return s;
  }
  return null;
}

function ymd(pubDate) {
  const d = new Date(pubDate);
  if (isNaN(d)) return '';
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}.${p(d.getMonth() + 1)}.${p(d.getDate())}`;
}

function excerpt(item) {
  const t = (item.desc || '').replace(new RegExp(esc(item.title), 'g'), '').trim();
  const clean = t.replace(/^[\s·—-]+/, '');
  return clean.length > 90 ? clean.slice(0, 88) + '…' : (clean || item.title);
}

function replaceBlock(html, inner) {
  const S = '<!-- AUTO:ARTICLES:START -->';
  const E = '<!-- AUTO:ARTICLES:END -->';
  const i = html.indexOf(S), j = html.indexOf(E);
  if (i < 0 || j < 0) throw new Error('找不到 AUTO:ARTICLES 標記');
  return html.slice(0, i + S.length) + '\n' + inner + '    ' + html.slice(j);
}

const main = async () => {
  const res = await fetch(FEED, { headers: { 'user-agent': 'yiding-articles-bot' } });
  if (!res.ok) throw new Error(`RSS ${res.status}`);
  const items = parseItems(await res.text());

  const seen = new Set();
  const picked = [];
  for (const it of items) {
    const site = siteOf(it);
    if (!site) continue;
    if (!KEYWORDS.some(k => it.title.includes(k))) continue;
    if (BLOCK.some(k => it.title.includes(k))) continue;
    if (seen.has(it.title)) continue;
    seen.add(it.title);
    picked.push({ ...it, site, date: ymd(it.pubDate), ex: excerpt(it) });
    if (picked.length >= MAX_LIST) break;
  }

  if (picked.length < 4) {
    console.log(`只找到 ${picked.length} 篇合格文章，未達 4 篇門檻，維持原內容不變。`);
    return;
  }

  // 首頁：卡片
  const cards = picked.slice(0, MAX_INDEX).map(p => `      <a class="article-card reveal" href="${esc(p.link)}" target="_blank" rel="noopener">
        <i class="corner tl"></i><i class="corner tr"></i><i class="corner bl"></i><i class="corner br"></i>
        <span class="article-tag">建築美學</span>
        <h3 class="article-title">${esc(p.title)}</h3>
        <p class="article-excerpt">${esc(p.ex)}</p>
      </a>
`).join('');
  let index = await readFile('index.html', 'utf8');
  index = replaceBlock(index, `    <div class="articles-grid">\n${cards}    </div>\n`);
  await writeFile('index.html', index);

  // 文章頁：列表
  const rows = picked.map(p => `      <a class="article-row" data-cat="aesthetics" href="${esc(p.link)}" target="_blank" rel="noopener">
        <span class="row-date">${esc(p.date)}</span>
        <div class="row-content">
          <h3>${esc(p.title)}</h3>
          <p>${esc(p.ex)}</p>
          <p class="row-source">原文出處：${esc(SOURCE_LABEL[p.site] || p.site)} →</p>
        </div>
        <span class="row-tag">建築美學</span>
      </a>
`).join('');
  let articles = await readFile('articles.html', 'utf8');
  articles = replaceBlock(articles, `    <div class="articles-list">\n${rows}    </div>\n`);
  await writeFile('articles.html', articles);

  console.log(`更新完成：首頁 ${Math.min(picked.length, MAX_INDEX)} 張卡片、文章頁 ${picked.length} 列`);
  picked.forEach((p, i) => console.log(`  ${i + 1}. [${p.date}] ${p.title} (${p.site})`));
};

main().catch(err => { console.error(err.message); process.exit(1); });
