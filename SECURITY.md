# Security policy

[简体中文](#安全策略)

GoldenPassport stores the secrets that generate your two-factor codes. If you find a way to get
at them that you shouldn't have, please tell us privately.

## Supported versions

| Version | Supported |
|---|---|
| 0.2.x, from this repository | ✅ |
| 0.1.x, from the archived [stanzhai/GoldenPassport](https://github.com/stanzhai/GoldenPassport) | ❌ Please upgrade |

Until the first 0.2.0 release is published, fixes land in the `modernize` branch.

## Reporting a vulnerability

Use [Report a vulnerability](https://github.com/thatscode/GoldenPassport/security/advisories/new)
rather than a public issue. Only you and the maintainers can see the report.

Please include:

- the GoldenPassport and macOS versions
- what an attacker can do, and the steps to reproduce it

**Never include real secrets**: no `otpauth://` URLs, QR codes, secret keys or verification
codes, and no files from `~/Library/Application Support/GoldenPassport/` or
`~/GoldenPassport-backups/`. Use made-up accounts.

## Known limitations

These are documented in the README and are not vulnerabilities in themselves:

- Secrets are stored unencrypted, protected by owner-only file permissions. Optionally storing
  them in the Keychain is on the [roadmap](README.md#roadmap).
- The HTTP API has no password: while it runs, anything running as you on the Mac can read
  every code. It is off on new installs.
- An upgrade from 0.1.x leaves unencrypted copies (installer backups and `gp.secrets`) until
  you run `cleanup.sh`. See [Data & security](README.md#data--security).

A way around these protections, such as another user account reading your data or a web page
reading your codes, is a vulnerability: please report it.

---

# 安全策略

GoldenPassport 保存着生成两步验证码的密钥。如果你发现了不该能拿到它们的途径，请私下告诉我们。

## 支持的版本

| 版本 | 是否支持 |
|---|---|
| 0.2.x，来自本仓库 | ✅ |
| 0.1.x，来自已归档的 [stanzhai/GoldenPassport](https://github.com/stanzhai/GoldenPassport) | ❌ 请升级 |

第一个 0.2.0 正式版发布之前，修复都在 `modernize` 分支上。

## 报告漏洞

请通过 [Report a vulnerability](https://github.com/thatscode/GoldenPassport/security/advisories/new)
私下报告，不要公开提 issue。报告只有你和维护者能看到。

请写明：

- GoldenPassport 和 macOS 的版本
- 攻击者能做到什么，以及复现步骤

**不要附上任何真实的密钥**：不要贴 `otpauth://` URL、二维码、密钥或验证码，也不要附上
`~/Library/Application Support/GoldenPassport/` 或 `~/GoldenPassport-backups/` 里的文件。
需要示例时，用虚构的账号。

## 已知限制

下面这些在说明文档里已经写明，本身不算漏洞：

- 密钥未加密保存，只靠文件权限保护（仅本人可读）。可选地改存到钥匙串，已列入[后续计划](README.zh-CN.md#后续计划)。
- HTTP 接口没有访问密码：开启期间，这台 Mac 上以你的身份运行的任何程序都能读取全部验证码。全新安装时默认关闭。
- 从 0.1.x 升级后，未加密的副本（安装备份和 `gp.secrets`）会一直保留，直到你运行 `cleanup.sh`。见[数据与安全](README.zh-CN.md#数据与安全)。

如果能绕过这些保护，例如其他用户账号读到你的数据，或者网页读到你的验证码，那就是漏洞，请报告。
