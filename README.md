<img src="https://i.postimg.cc/Xqgn5vhV/samoyed-i-OS-Default-1024x1024-1x.png" width="150">

# Bitarf RI

Bitarf RI 是一個以繁體中文 iOS 長紙捲版面編輯器 app 的重建資料庫。它保留文件管理、畫布編輯、文字排版、向量與圖片匯入、遞色、預覽及基礎 Bluetooth 介面的程式，並以一個「經典機型」為範例提供印表機硬體完整實作的 coding agent 用重建提示詞。

## Disclaimer
This is a product of cognitive automation. Interact with codes, prompts, and built artifacts inside with care. 

![](https://i.postimg.cc/jqBH3SD0/STIIITCH-2026-08-20-07-43-05.png)

## 專案內容

- Bitarf RI/：iOS App 的 SwiftUI、UIKit、文件、編輯器與資源骨架。
- Sources/BitarfRICore/：文件模型、畫布物件、排版、遞色與點陣處理等核心內容。
- Bitarf RI.xcodeproj/：Xcode project。

此資料庫不含原始 Git 歷史、簽署憑證、provisioning profile、Apple Team ID、開發者帳號、測試資料或建置產物。

## 前提需求
若要完整重建並使用，需要以下能力、資格與環境：
- 繁體中文識讀能力
- Apple 帳號與付費的 Apple 開發者方案
- iOS 26 或以上版本裝置與 SDK

或透過以下犧牲來規避需求：
- 語言能力：可交代 coding agent 以其他語言改寫 UI 。
- 付費的 Apple 開發者方案：可交代 coding agent 略過 user-fonts entitlement 與文字地區變體相關支援。

## 使用方法
此 repo **不完整、不可直接建置**。Pull 專案後，使用 coding agent（程式碼自動化編寫程式）實作缺少的協定、硬體 profile、BLE adapter、列印工作與實測參數來完成重建後形成可執行的 Xcode  iOS app 專案。

先交代 coding agent 讀取本 README.md。由 coding agent 尋找缺少功能所對應的提示詞檔案。每個有硬體缺口的資料夾只有一份提示詞，內容只涵蓋該資料夾直接包含的檔案。重建用提示詞檔案包含：

- Bitarf RI.md
- Sources/BitarfRICore/BitarfRICore.md
- Bitarf RI/Bitarf RI.md
- Bitarf RI/App/App.md
- Bitarf RI/Canvas/Canvas.md
- Bitarf RI/Model/Model.md
- Bitarf RI/Panels/Panels.md
- Bitarf RI/Printing/Printing.md

原地保留的「此處應插入⋯⋯」註解及 string catalog reconstruction metadata 是明確的回填位置。提示詞以文字形式保存功能、UI、經典機型的封包欄位、常數、實測值與相容性行為。

建議重建順序：

1. 核心硬體 profile 與 wire protocol。
2. 點陣工作分段及串流節流。
3. CoreBluetooth adapter、回覆解析與裝置狀態。
4. 文件預設值、設定表、列印 UI 與繁體中文文案。
5. 另行建立測試並以實機驗證封包、CRC、濃度、走紙與長文件節流。

## 致謝

Bitarf RI 的自動化程式在編寫時，從以下專案獲得啟發：
- [tinyprinter/python-paperang](https://github.com/tinyprinter/python-paperang)
- [Yrr0r/paperang-web](https://github.com/Yrr0r/paperang-web)

##  授權
不得將 Bitarf RI 品牌改為 Bitarf。除此之外，Fork 專案後你愛幹嘛幹嘛。


##### 2026 Instructed by PY Cognitive Automations in Taiwan
