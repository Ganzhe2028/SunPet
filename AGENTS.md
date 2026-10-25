# AGENTS.md

给在这个仓库里干活的 AI。人看的在 [README.md](README.md)，技术细节在 [TECHNICAL.md](TECHNICAL.md)，素材权利在 [NOTICE.md](NOTICE.md)。

## 构建与验证

- `./build.sh` 编译并跑 `--self-test`，最后一行必须是 `PASS`。没 PASS 就是没改完。
- 没有 `install.sh`，也没有 `build.sh --package`。安装就是拖 `build/SunPet.app` 进「应用程序」；打包装用 `ditto -c -k --keepParent build/SunPet.app dist/SunPet-<版本>.zip`、`hdiutil create -quiet -volname SunPet -srcfolder build/SunPet.app -ov -format UDZO dist/SunPet-<版本>.dmg`，再 `shasum -a 256`。
- 只支持 Apple Silicon + macOS 14，构建脚本里写死 arm64，不要为 Intel 改。
- 诊断入口：`--self-test`、`--dump-mode`、`--trace`

## 不能破的约束

- `Sources/Bridge.swift` 在 SunPet / ShaolanPet / FengGe-Desktop-Pet 三个仓库里必须逐字节相同。改一处要三处同步，验法：`md5 -q Sources/Bridge.swift` 三份一致。
- `LICENSE` 只放标准 MIT 全文。素材权利写在 `NOTICE.md`，第三方代码许可放 `licenses/`。往 LICENSE 末尾追加例外会让 GitHub 判成 `NOASSERTION`，按 MIT 筛选就搜不到；验法 `gh api repos/Ganzhe2028/SunPet --jq .license.spdx_id` 要返回 `MIT`。
- README 是给刷到视频的普通人看的落地页，只放四块：四张脸互链、装三步、一句自己的效果、立场。技术长文一律进 TECHNICAL.md。
- README 顶部四张脸是四个独立 App 的互链，不是同一个 App 的皮肤。这句说明不能删。
- 二进制不进仓库，安装包走 Releases。

## 发布

SunPet 没有 release workflow，`.github/workflows/build.yml` 只在每次 push 时跑一遍构建和自检。
发版手动：本地 `./build.sh` 打包出 dmg/zip/sha256，再 `gh release upload <tag> dist/* -R Ganzhe2028/SunPet`。
资产命名跟另外两个仓库保持一致（`SunPet-<版本>.dmg`），README 写死「下载最新的 `.dmg`」。

## 联动

三个桌宠靠 `DistributedNotificationCenter` 互相接话，`hop` / `root` 两个字段防环。加角色先读 TECHNICAL.md 的《加第四个人》，同时确认 peers、hop 上限、root 条件三处。`--self-test` 不覆盖联动，别靠 PASS 宣布通了。第四个 [JellyPet](https://github.com/aurelius358/JellyPet) 是别人做的形状挂件，没有语音，不在这套协议里。

## 这个仓库

- app：`SunPet.app`，bundle id `com.ganzhe2028.sunpet`
- 四步链位置：太对了，谁说话都接
- peers：`[.fengge, .shaolan]`
