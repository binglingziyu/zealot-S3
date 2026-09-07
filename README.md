> **S3 storage fork**: This branch adds private S3/MinIO/OSS storage and signed direct downloads to Zealot 6.2.2. See [configuration, migration and deployment](docs/s3-storage.md) and [integration tests](test/s3/README.md). Build with `Dockerfile.s3`. Default local filesystem storage remains supported.

<div align='center'>
  <a href="https://www.producthunt.com/posts/zealot?utm_source=badge-featured&utm_medium=badge&utm_souce=badge-zealot" target="_blank"><img src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=322207&theme=light" style="width: 250px; height: 54px" width="250" height="54" /></a>

  <h1>Zealot</h1>

  <h4>
    开源自部署持续集成一切跟应用有关事情，接入任意 CI 系统一切自动化处理，企业多年实战经验，独立部署提供企业打包分发流程、上传应用全套流程方案 En Taro Adun! 🖖
    <br />
    Continuous everything. Automate the lifecycle of your apps. Connect your CI to build in the cloud, test on thousands of real devices, distribute to beta testers and app stores. All in one place.
  </h4>

  <a href="https://github.com/tryzealot/zealot/blob/develop/CHANGELOG.md">
    <img alt="changelog" src="https://img.shields.io/github/v/release/tryzealot/zealot?include_prereleases">
  </a>
  <a href="https://ghcr.io/tryzealot/zealot">
    <img alt="docker image" src="https://img.shields.io/docker/pulls/tryzealot/zealot.svg">
  </a>
  <a href="https://t.me/+csa3Y2KOx44wMGRl">
    <img alt="chat on telegram" src="https://img.shields.io/badge/chat-on%20telegram-important.svg">
  </a>
  <a title="Crowdin" target="_blank" href="https://crowdin.com/project/zealot"><img src="https://badges.crowdin.net/zealot/localized.svg"></a>
  <a href="https://codeclimate.com/github/tryzealot/zealot/maintainability">
    <img alt="codeclimate" src="https://api.codeclimate.com/v1/badges/f79b2fed0ce166b2ea2c/maintainability" />
  </a>
  <a href="https://www.codacy.com/gh/tryzealot/zealot/dashboard?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=tryzealot/zealot&amp;utm_campaign=Badge_Grade">
    <img alt="codacy" src="https://app.codacy.com/project/badge/Grade/5e5c7bbeb1214fa39b11a7414f0d7171"/>
  </a>

  <div>
    <a href="https://zealot.ews.im/docs/self-hosted">Install</a> •
    <a href="https://zealot.ews.im/docs/developer-guide/api">REST API</a> •
    <a href="https://zealot.ews.im/docs/developer-guide">Developer guide</a> •
    <a href="https://zealot.ews.im/docs/user-guide">User guide</a>
  </div>

  <div>
    <a href="https://zealot.ews.im/zh-Hans/docs/self-hosted">自部署</a> •
    <a href="https://zealot.ews.im/zh-Hans/docs/developer-guide/api">API 接口</a> •
    <a href="https://zealot.ews.im/zh-Hans/docs/developer-guide">开发者资源</a> •
    <a href="https://zealot.ews.im/zh-Hans/docs/user-guide">用户使用手册</a>
  </div>
</div>

![Zealot Showcase](https://github.com/tryzealot/docs/blob/main/static/img/showcase-light.png#gh-light-mode-only)
![Zealot Showcase](https://github.com/tryzealot/docs/blob/main/static/img/showcase-dark.png#gh-dark-mode-only)

## 特性

- 🌏 **多平台应用托管**: macOS、iOS、Android（apk/aab）、Windows、Linux 泛平台
- 📱 **测试设备一网打进**: 自动同步 iOS 测试设备信息，允许一键注册新设备到苹果开发者
- 🧑‍💻 **丰富开发者套件**: 提供 REST API、[iOS][zealot-ios-sdk]、[Android][android-android-sdk] SDK 以及 [fastlane][fastlane-plugin-zealot] 自动化构建插件
- 💥 **剖析应用内部的秘密**: 解读 iOS、Android 应用或 iOS 描述文件的元信息
- 🚨 **内置多种事件通知**: 数据可自定义 Income WebHook 到任意通知服务
- 🗄 **多渠道分类管理**: 自由划分不同场景不同产品形态的应用渠道管理
- 🎳 **多架构部署**: amd86/arm64 及各种部署方案应有尽有
- 🔑 **第三方登录**: 飞书、Gitlab、Github、Google、LDAP 和 OIDC 一键授权
- 🌑 **黑暗模式**: 黑夜白昼自由切换

## 在线演示

- 演示地址：https://tryzealot.ews.im
- 中文账户: `cn_admin@zealot.com` / `ze@l0t`
- English Account: `en_admin@zealot.com` / `ze@l0t`

> **注意**: 演示服务中的数据每日都会重新初始化，不对用户上传的应用承担任何法律风险，后果自负！

## 开发统计

![Alt](https://repobeats.axiom.co/api/embed/caba5e356c0e8258d395aaa9f70fec475a2eb643.svg "Repobeats analytics image")

## 发布协议

[MIT][mit-link]


[zealot-ios-sdk]: https://github.com/tryzealot/zealot-ios
[android-android-sdk]: https://github.com/tryzealot/zealot-android
[fastlane-plugin-zealot]: https://github.com/tryzealot/fastlane-plugin-zealot
[mit-link]: https://github.com/tryzealot/zealot/blob/develop/LICENSE
