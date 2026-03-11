# [KOReader Anna's Archive 插件](https://github.com/fischer-hub/annas.koplugin)

简体中文 | [English](./README.md)

**免责声明：** 本插件仅供教育用途。请遵守版权法并自行承担使用责任。

这个 KOReader 插件用于搜索 Anna's Archive，并通过 Anna 的公开镜像页面下载文件。当前实现基于网页抓取，不需要账号登录，也不再支持 Z-library 时代的邮箱、密码、基础 URL、会话或 RPC 配置。

## 功能特色

- 搜索 Anna's Archive 条目。
- 按语言、格式和排序方式筛选结果。
- 直接从结果详情页触发下载。
- 配置下载目录和网络超时选项。

## 安装方法

1. 下载最新发布中的 `annas.koplugin.zip`。
2. 解压后确认目录名是 `annas.koplugin`。
3. 将该目录复制到设备上的 `koreader/plugins`。
4. 重启 KOReader。

## 使用方法

1. 确保当前位于 KOReader 文件浏览器。
2. 打开“搜索”菜单。
3. 选择“Anna's Archive”。
4. 输入关键词，并按需调整排序、语言、格式、下载目录或超时设置。
5. 打开一个搜索结果。
6. 点击格式一行开始下载。

说明：

- 不需要账号登录。
- 不再提供 `annas_credentials.lua` 覆盖文件。
- 旧版“推荐图书”“最受欢迎图书”等 Z-library API 入口已移除，因为它们不属于当前 Anna 搜索/下载流程。

## 手势设置（可选）

如果你想通过手势直接打开搜索：

1. 打开顶部菜单并点击设置图标。
2. 进入“点击与手势” > “手势管理器”。
3. 选择一个手势。
4. 在“一般”分类中勾选 “Anna's Archive search”。

## 本地化支持

多语言文件位于 [l10n/README.md](./l10n/README.md)。未翻译的字符串会回退为英文。

## DNS 建议

如果 Anna's Archive 在你的网络环境下经常无法访问，优先考虑在路由器上将 DNS 设置为 `1.1.1.1`。只有在无法修改路由器时，才建议在阅读器设备上手动修改系统 DNS。英文 README 保留了设备级操作步骤。

## 关键词

KOReader、Anna's Archive、电子阅读器、插件、电子书、下载、数字图书馆、电子墨水、阅读、开源。
