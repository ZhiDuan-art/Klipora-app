<div align="center">

<img src="banners/klipora-banner-ja.png" alt="Klipora ヒーローバナー" width="100%" />

# Klipora

**Apple Silicon 向けローカル AI 画像生成・音声合成・マルチトラック動画編集スタジオ**

*Clip（`Klip`）× 光のオーラと空間感（`-ora`）— macOS でオフライン完結するクリエイティブ環境。*

[English](../README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md) · **日本語** · [한국어](README.ko.md)

[![Platform](https://img.shields.io/badge/macOS-14.0%2B%20Apple%20Silicon-111113?style=flat-square)](#推奨動作環境)
[![Languages](https://img.shields.io/badge/対応言語-繁中%20%7C%20简中%20%7C%20EN%20%7C%20日本語%20%7C%20한국어-4F8BFF?style=flat-square)](#5ヶ国語ローカライズ)
[![Release](https://img.shields.io/badge/ダウンロード-v1.1.6%20DMG-F46B53?style=flat-square)](https://github.com/ZhiDuan-art/Klipora-app/releases)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4%20Support%20Klipora-EA4AAA?style=flat-square)](https://portaly.cc/chihtuan)
[![更新・デバッグ履歴](https://img.shields.io/badge/Changelog-Debug%20Log-2B2B30?style=flat-square)](../CHANGELOG.md)

</div>

---

> **最新アップデート — `v1.1.6`（2026-11-26 00:55 UTC+8）**：Google Colab 連携を大幅強化（**`A100` GPU**、**`10Eros-Max 8-step`** モデル、**最大 60 秒の自動シームレス延長**、**15 分間ウォーム GPU 保持トグル**、**起動時自動再接続**、**`503` 自動リトライ**対応）。さらに **9 種類の定番比率**（`3:4`・`4:3`・`2:3`・`3:2`・`4:5`・`5:4`）、**`1K / 2K / 4K / 8K` 解像度出力**、常時表示の **Denoise スライダー＆解説**、**`Klipora-*` ファイル名統一**と動画プレビューのレイアウト崩れ修正を実装。詳細は **[更新・デバッグ履歴（CHANGELOG.md）](../CHANGELOG.md)** · **[v1.1.6 DMG をダウンロード](https://github.com/ZhiDuan-art/Klipora-app/releases/tag/v1.1.6)**。

## 実機デモ動画

*`v1.1.1` 実機画面＋ローカル Qwen3-TTS ナレーション（新カプセル UI・6 タブ設定・Breeze-ASR-26 対応）：*
**[▶ v1.1.1 英語版 1080p を見る](https://github.com/ZhiDuan-art/Klipora-app/releases/download/v1.1.1/Klipora-Promo-en-1080p.mp4)** · **[▶ v1.1.1 繁體中文版 1080p](https://github.com/ZhiDuan-art/Klipora-app/releases/download/v1.1.1/Klipora-Promo-zh-Hant-1080p.mp4)**

https://github.com/user-attachments/assets/cf44c254-edec-46e1-83d6-0114225d340c

<details>
<summary>▶ 繁體中文ナレーション版を見る（60s）</summary>

https://github.com/user-attachments/assets/8410f8b6-4835-4497-a124-40e8544bfab2

</details>

---

## インターフェース紹介

| ローカル音声・ボイススタジオ | AI 画像生成ワークスペース |
| :---: | :---: |
| ![ローカル音声・ボイススタジオ](screenshots/01-startup-selfcheck.png) | ![画像生成ワークスペース](screenshots/02-generate-workspace.png) |

| マルチトラック動画編集 | 環境・多言語・接続設定 |
| :---: | :---: |
| ![動画編集ワークスペース](screenshots/03-edit-workspace.png) | ![環境・接続設定](screenshots/04-settings-connections.png) |

---

## 主な特徴

- **ローカル完結の AI 画像・動画生成**：ComfyUI ネイティブ連携（厳選 4 大画像モデル `Z-Image Turbo`、`RedCraft 1.5 AIO`、`MOSS-Image BF16`、`Krea-2 Turbo BF16`＋ローカル `Wan 2.2 14B MoE 4-step` 動画対応）、**9 種類の定番比率＋元画像比率自動適応＋`1K / 2K / 4K / 8K` 解像度**、常時表示の **Denoise スライダー解説**、カスタム `.safetensors` / LoRA 管理に対応。
- **ネイティブ・マルチトラック動画編集**：SwiftUI + CoreText 字幕描画 + FFmpeg + HyperFrames により、**マーキー複数選択**、一括リップル削除、映像・音声・字幕トラック編集、トランジション、エフェクト、MP4 書き出しを高速処理。
- **ローカル音声スタジオ**：**`MediaTek BreezyVoice`**（68 ボイス共有）、**`Qwen3-TTS 1.7B`**、**`Chatterbox Turbo`**、オフライン **`Breeze-ASR-26`** 自動字幕＆ボーカル分離を内蔵。
- **強化された Google Colab＆公式 API 連携**：起動時自動再接続、**L4 / G4 / A100** GPU、**`UPD5` / `10Eros-Max 8-step` / `PRISM`** 動画モデル、**60 秒自動連結生成**、**15 分ウォーム GPU 保持**、`503` 自動リトライに加え、任意で OpenAI / Gemini 公式画像 API も利用可能（キーは macOS キーチェーンにのみ保存）。
- **起動時セルフチェック＆4ステップ初期セットアップ**：起動ごとに主要エンジンを診断。初回はハードウェア診断・ComfyUI 設定・容量表示付きモデル選択ダウンロード・任意ログインを案内。

---

## 5ヶ国語ローカライズ

「環境・接続設定」または「初期セットアップ」から再起動なしで即座に切り替え可能：**繁體中文 / 简体中文 / English / 日本語 / 한국어**。

---

## 推奨動作環境

| 構成 | Mac ハードウェア | ユニファイドメモリ | 空き容量 | 推奨ワークフロー |
| :--- | :--- | :--- | :--- | :--- |
| **標準** | Apple Silicon (M1–M5) | 16 GB | 25 GB 以上 | Z-Image Turbo / RedCraft + BreezyVoice / Qwen3-TTS + マルチトラック編集 |
| **プロ / 上位** | Apple Silicon Pro / Max / Ultra | 24–64 GB 以上 | 80 GB 以上 | Z-Image / RedCraft / MOSS / Krea-2 + Wan 2.2 14B MoE + 複数 LoRA |
| **クラウド併用** | 任意の Apple Silicon Mac | 16 GB | 10 GB 以上 | ローカル編集 + Google Colab (L4/G4/A100) / 公式 Web・API |

---

## インストール方法

1. [GitHub Releases](https://github.com/ZhiDuan-art/Klipora-app/releases) から **`Klipora-1.1.6-arm64.dmg`** をダウンロードし、**Klipora.app** を **Applications** へドラッグします。
2. 初回起動時に警告が表示された場合は、**Klipora.app を右クリック → 開く → 開く** で起動してください。
3. Codex や各種 AI エージェントに `https://github.com/ZhiDuan-art/Klipora-app` を渡し、**[DEPLOY_WITH_AI.md](../DEPLOY_WITH_AI.md)** に従って自動セットアップすることも可能です。

---

## 開発を支援する

Klipora が制作ワークフローのお役に立てば、継続的な開発へのご支援をいただけると嬉しいです（クレジットカード・PayPal 対応）：

[![Support Klipora](https://img.shields.io/badge/Support%20Klipora-%E2%9D%A4%20Portaly-EA4AAA?style=for-the-badge)](https://portaly.cc/chihtuan)

- **継続メンテナンス**：最新の ComfyUI ワークフロー、ローカル画像・動画・音声モデル、5言語対応のアップデートを継続します。
- **今後の希望（保証なし）**：将来的に十分なご支援が集まった場合、macOS の警告を軽減するための Apple 公証（Notarization）対応を検討したいと考えていますが、実現を保証するものではありません。

---

## ライセンス・お問い合わせ

Copyright © 2026 **Chih Tuan Chang**（[meteor199311@gmail.com](mailto:meteor199311@gmail.com)）. All rights reserved.
