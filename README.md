# 義鼎不動產官網 — 上傳說明

## 倉庫
`kcc0938188881-arch/kcc0938188881-arch.github.io`（branch: main）
網址：https://kcc0938188881-arch.github.io

## 上傳步驟
1. 解壓縮這個 zip
2. 到倉庫頁面，把**倉庫裡原有的檔案先刪掉**（勾選 → Delete file → Commit）
3. `Add file` → `Upload files`
4. **全選解壓後的所有檔案和資料夾**拖進去（含隱藏的 `.github` 資料夾）
5. `Commit changes`
6. 等 1–2 分鐘，開網址確認

> `.github` 資料夾在某些系統是隱藏的。Windows 請在檔案總管勾「隱藏的項目」；Mac 按 `Cmd + Shift + .` 顯示。

## 上線後必做兩件事

### 1. 啟用聯絡表單（否則收不到客戶詢問）
1. 開網站，捲到「聯絡我們」，自己填一筆測試資料送出
2. FormSubmit 會寄確認信到 kcc.0938188881@gmail.com
3. **點信中的連結啟用** — 沒點的話客戶填的內容不會寄出

### 2. 開啟自動更新權限
1. 倉庫 `Settings` → `Actions` → `General`
2. 最下方 Workflow permissions 選 **Read and write permissions** → Save
3. `Actions` 頁籤 → `定期更新網站內容` → `Run workflow` 手動跑一次，確認抓取正常

## 檔案結構
```
index.html          首頁
projects.html       精選土地列表（21 筆、四分類篩選）
detail.html         物件詳情（?id=N，照片輪播）
articles.html       建築美學
thanks.html         表單送出後的感謝頁
styles.css          設計系統樣式（已內嵌所有 token）
*.jpg               物件照片 125 張、人像、Hero 背景、展覽主視覺
.github/workflows/  自動更新排程
scripts/            自動更新腳本
```

## 自動更新機制
| 內容 | 頻率 | 標記範圍 |
|---|---|---|
| 首頁不動產要聞（8 則） | 每月 1、15 號 | `<!-- AUTO:NEWS -->` |
| 建築美學文章 | 每月 1 號 | `<!-- AUTO:ARTICLES -->` |

頭條新聞、精選土地、品牌介紹、聯絡資訊都在標記範圍外，腳本不會動到 — 要改請找我。

抓不到足夠的合格文章時會維持原內容不動，不會把版面弄空。

## 要修改內容時
把新的照片資料夾或文字傳給我，我改好 `deploy/` 再打包給您重新上傳。不要直接在 GitHub 上編輯 HTML，避免下次覆蓋時衝突。
