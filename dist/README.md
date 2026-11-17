# 宽途 KuanTu · 单文件安装包

下载并双击：

```text
KuanTu-Setup.exe
```

无需解压，不需要管理员权限。

安装位置：

```text
%LOCALAPPDATA%\KuanTu
```

首次使用：

1. 填写宽带账号和密码；
2. 点“保存并启用自动连接”；
3. 之后登录 Windows 会自动拨号，掉线自动重连。

如果 Windows SmartScreen 提示“已保护你的电脑”，点“更多信息” → “仍要运行”。这是未签名本地程序的正常提示。

SHA-256：

```text
69A2D9A48EE2818F0E2AC70DE74254BB30D307BEE5CB5E4BE56AF5EA83F7FFCF
```

适用：Windows 11 + PPPoE 拨号的校园网/宽带；Web 认证、802.1X 场景不适用。

> 如果你已经通过安装器装过宽途，请继续使用 `%LOCALAPPDATA%\KuanTu`；不要在本源码目录再次保存设置，否则会生成第二套自启任务。


> 重新打包安装器时，请先排除 `dist` 目录，避免把安装包自身打进 payload。

