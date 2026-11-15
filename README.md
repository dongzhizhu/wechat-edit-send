# 微信插件：长按图片 → 编辑发送

功能：长按聊天里的一张图片，菜单在“保存图片”上面多一项“编辑发送”。
点它打开编辑器（涂鸦 / 文字 / 马赛克 / 撤销），编辑完点发送，发到当前会话。

- 目标：微信 iOS 8.0.76，证书自签注入（全能签 / 轻松签）
- 写法：单个 `.m` 文件，纯 ObjC runtime，不依赖 CydiaSubstrate / Theos / Logos
- 文件：`EditAndSend.m`（全部代码都在里面）

## 编译

需要 iOS SDK + clang（Mac 上用 Xcode 自带的）：

```bash
clang -dynamiclib -arch arm64 -mios-version-min=12.0 -fobjc-arc \
  -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
  -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
  EditAndSend.m -o EditAndSend.dylib
```

## 没有 Mac 时的编译（GitHub Actions，2026-11-15 已备好）

- dong 没有 Mac，但有 GitHub 账号：仓库里放 `EditAndSend.m` + `.github/workflows/build-dylib.yml`（已写好，随代码放在一起），Actions 里运行 Build dylib，跑完在 Artifacts 下载 `EditAndSend-dylib`。
- 免费额度内的公开/私有仓库都能用，不用自己搭 Mac。

## 安装

1. 准备已砸壳的微信 8.0.76 IPA（App Store 直接下载的加密 IPA 不行）。
2. 全能签 / 轻松签：导入 IPA → 注入 `EditAndSend.dylib` → 证书签名 → 安装。
3. 打开微信，长按一张图片，看菜单里“保存图片”上面有没有“编辑发送”。

## 查实了什么 / 还差什么

| 部分 | 状态 |
|---|---|
| 长按菜单 `WCActionSheet`，`addButtonWithTitle:atIndex:` 加项 | ✅ 已查实（有开源插件先例 WeChatShot） |
| 聊天窗口 `BaseMsgContentViewController`、图片节点 `ImageMessageNodeView`、消息 `CMessageWrap`（type 3 = 图片） | ✅ 已查实 |
| `CMessageMgr` 取法 | ✅ 已查实 |
| 自签注入（insert_dylib + 纯 runtime，不用 substrate） | ✅ 已查实 |
| 发图片的私有方法名 | ⚠️ **没查到**。公开资料没有 8.0.76 的头文件 |
| 微信内置图片编辑器的类名 | ⚠️ **没查到**，所以插件自带了一个简易编辑器 |
| 被长按图片的 UIImage、当前会话用户名 | ⚠️ 代码里用运行时 ivar 扫描做最佳努力，需按头文件核对 |
| 长按菜单里找“保存图片”的位置 | ⚠️ 2026-11-15 晚复查改成两种都认：`buttonTitleList` 里可能是 NSString，也可能是带 `title` 属性的对象，8.0.76 头文件没拿到、没法确认，原代码只认后者——若实际是 NSString，菜单项会悄悄插不进去。现在两种都认，只会更稳 |

## 现在的发送是怎么做的

发图片在微信底层是两步：先传 CDN 拿 key，再发消息。直发的方法名没查到，所以代码里
目前是兜底：**编辑完点发送 → 图存进剪贴板 → 提示你点输入框粘贴发送**。
菜单、编辑器、上下文捕获都是完整的，只差最后一步直发。

## 补全直发要做的事

```bash
# 1) 对已砸壳的 8.0.76 二进制做 class-dump
class-dump -H /path/to/WeChat.app/WeChat -o ~/wx-headers

# 2) 找发图片的方法和上传管理器
grep -n "Image\|AddMsg\|SendMsg" ~/wx-headers/CMessageMgr.h
ls ~/wx-headers | grep -i "Upload.*Image\|Image.*Upload"

# 3) 核对菜单和编辑器
grep -n "addButtonWithTitle\|showInView\|buttonTitleList" ~/wx-headers/WCActionSheet.h
grep -n "actionSheet:clickedButtonAtIndex:" ~/wx-headers/BaseMsgContentViewController.h
```

把确认到的方法名填进 `EditAndSend.m` 里 `ESSendEditedImage` 的 TODO(1) 处，
并把 `ES_FindImageMessageWrap` / `ES_PeerUserName` 里的 ivar 名按头文件对一遍，
重新编译、注入、签名就能直发。也可以把 dump 出来的头文件发给助理，让助理补全。

## 注意事项

- 免费个人证书 7 天掉签，到期重签。
- 微信升级后插件大概率失效甚至闪退，要按新版本重对接口。
- 微信技术上能发现注入（枚举 dylib、校验签名），账号风险自己承担。
- 代码没在真机上编译验证过，编的时候报错信息发回来一起看。
