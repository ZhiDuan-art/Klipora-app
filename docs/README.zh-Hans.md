<div align="center">

<img src="../work/studio/resources/KliporaLogo.png" alt="Klipora" width="128" />

# Klipora

**专为 Apple Silicon 打造的本地 AI 图像生成、语音配音与多轨剪辑工作站**

*取自 Clip（`Klip`）× 光晕与空间感（`-ora`）——在 macOS 上离线完成生图、配音、剪辑与导出。*

[English](../README.md) · [繁體中文](README.zh-Hant.md) · **简体中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

[![Platform](https://img.shields.io/badge/macOS-14.0%2B%20Apple%20Silicon-111113?style=flat-square)](#硬件需求建议)
[![Languages](https://img.shields.io/badge/支持语言-繁中%20%7C%20简中%20%7C%20EN%20%7C%20日本語%20%7C%20한국어-4F8BFF?style=flat-square)](#5-国语言本地化)
[![Release](https://img.shields.io/badge/下载-v1.0.0%20DMG-F46B53?style=flat-square)](https://github.com/ZhiDuan-art/Klipora-app/releases)

</div>

---

## 界面展示

| 启动自检画面 | AI 图像生成工作区 |
| :---: | :---: |
| ![启动自检画面](screenshots/01-startup-selfcheck.png) | ![生成工作区](screenshots/02-generate-workspace.png) |

| 多轨专业剪辑工作区 | 组件设置、多国语言与连接 |
| :---: | :---: |
| ![剪辑工作区](screenshots/03-edit-workspace.png) | ![组件与连接设置](screenshots/04-settings-connections.png) |

---

## 核心特色

- **本地优先 AI 图像生成**：原生集成 ComfyUI，内置 `SDXL 1.0`、`Z-Image Turbo`、`RedCraft`、`Iniverse FLUX`、`MOSS`、`Krea-2` 预设，支持自定义 `.safetensors` 模型管理、中央去重存储、兼容 LoRA 筛选与自定义 ComfyUI API 工作流。
- **原生多轨音视频剪辑**：结合 SwiftUI、CoreText 字幕标题渲染、FFmpeg 与 HyperFrames，支持视频／音频／字幕多轨剪辑、转场、滤镜与 MP4 导出。
- **本地神经语音工作室**：内置 MLX / Qwen3-TTS 语音合成、声音角色库管理与离线音频 AI 工具。
- **可选云端与官方 API**：集成 Google Colab OAuth（Wan 2.2 / H3 云端音视频）及明确授权后启用的 OpenAI / Gemini 官方图像 API（密钥仅存于 macOS 钥匙串，离线时本地功能完全可用）。
- **启动自检与 4 步首次引导**：每次启动自动检测核心引擎；首次使用提供硬件兼容检测、ComfyUI 安装与默认路径配置、多模型磁盘空间标注与勾选下载、以及可选登录引导。

---

## 5 国语言本地化

可在“组件与连接设置”或“安装引导”中免重启即时切换：**繁體中文**、**简体中文**、**English**、**日本語**、**한국어**。

---

## 硬件需求建议

| 等级 | Mac 硬件 | 统一内存 | 可用磁盘 | 推荐使用方式 |
| :--- | :--- | :--- | :--- | :--- |
| **标准** | Apple Silicon (M1–M5) | 16 GB | 25 GB+ | SDXL 1.0 Base + Qwen3-TTS + 多轨剪辑 |
| **旗舰** | Apple Silicon Pro / Max / Ultra | 24–64 GB+ | 80 GB+ | Z-Image Turbo / FLUX / Krea-2 / MOSS + 多组 LoRA |
| **云端混合** | 任一 Apple Silicon Mac | 16 GB | 10 GB+ | 本地剪辑 + Google Colab / 官方网页或可选 API |

---

## 安装方式

1. 前往 [GitHub Releases](https://github.com/ZhiDuan-art/Klipora-app/releases) 下载 **`Klipora-1.0.0-arm64.dmg`**，将 **Klipora.app** 拖入 **Applications**。
2. 首次打开若 macOS 提示无法验证开发者，请右键 **Klipora.app → 打开 → 打开**。
3. 也可直接将仓库链接 `https://github.com/ZhiDuan-art/Klipora-app` 交给你的 Codex／AI 工具，按 **[DEPLOY_WITH_AI.md](../DEPLOY_WITH_AI.md)** 自动部署。

---

## 版权与联系

Copyright © 2026 **Chih Tuan Chang**（[meteor199311@gmail.com](mailto:meteor199311@gmail.com)）. All rights reserved.
