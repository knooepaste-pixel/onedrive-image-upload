# OneDrive Image Upload

用 OneDrive 临时图片直链替代请求体里的 Base64，减少图片相关的 `413 Payload Too Large`。原图不压缩、不改像素；只上传你明确选择的文件。

**当前支持：Windows、PowerShell 7.2+、Python 3.11+、个人版 OneDrive。MIT 开源。**

它是按需调用的上传工具，也可以作为 Codex Skill 使用。不是全盘同步器、目录监控器或自动接管 Codex 请求的代理。安装它不会自动修改现有生图脚本或模型路由。

## 为什么可以缓解 413

Base64 是编码，不是压缩。`N` 字节的图片编码后约为 `4 × ceil(N / 3)` 字节，通常增加约 33%，还没算 JSON、提示词和历史消息。

```text
本地图片 -> OneDrive 应用文件夹 -> 验证临时 HTTPS 直链
                                    |
                                    v
AI 请求：提示词 + 图片 URL，不再内嵌整张图的 Base64
```

工具使用微软 Graph 返回的临时下载 URL，不创建永久公开分享链接。**拿到临时 URL 的人可以免登录读取该图片**，因此必须像凭据一样保护它。

## 安装

先安装 Windows 版 PowerShell 7.2+、Python 3.11+ 和 Git。在 `pwsh.exe` 中运行：

```powershell
git clone https://github.com/knooepaste-pixel/onedrive-image-upload.git
Set-Location onedrive-image-upload
pwsh.exe -NoProfile -File ./scripts/install.ps1
```

安装脚本创建仓库内的 `.venv`，安装固定版本的 Python 依赖，并在当前 Windows 用户范围内安装 `Microsoft.Graph.Authentication >= 2.41.2`，不要求管理员权限、不执行微软登录。需要 Python 包源和 PowerShell Gallery 可访问。可用 `-PythonExecutable <python.exe绝对路径>` 选择 Python。工具优先使用 `.venv/Scripts/python.exe`，其次使用 PATH 中的 `python`；环境变量 `ONEDRIVE_IMAGE_PYTHON` 可指定已有解释器。

### 首次授权

```powershell
pwsh.exe -NoProfile -File ./scripts/onedrive_image.ps1 -Action Status
pwsh.exe -NoProfile -File ./scripts/onedrive_image.ps1 -Action Connect
```

`Connect` 返回微软验证网址和一次性设备代码后退出。在微软页面登录个人账户并同意权限，然后**再运行一次 Connect** 接收并保存授权：

```powershell
pwsh.exe -NoProfile -File ./scripts/onedrive_image.ps1 -Action Connect
pwsh.exe -NoProfile -File ./scripts/onedrive_image.ps1 -Action Verify
```

仅请求委托权限 `Files.ReadWrite.AppFolder`。文件上传到该应用自己的 OneDrive 应用文件夹，而不是遍历整个网盘。Verify 会联网检查，必要时创建该应用文件夹；Status 只反映本地缓存，不能证明网络连接成功。

默认复用 Microsoft Graph Command Line Tools 的公共客户端 ID `14d82eec-204b-4c2f-b7e8-296a70dab67e`，不是密钥，本项目也不是微软官方项目。授权页面和应用文件夹可能显示该应用名。该客户端是否继续允许此权限受微软管理；默认客户端只用于兼容已有登录。

### 使用自己的微软应用（推荐用于独立部署）

在 Microsoft Entra 应用注册中创建支持个人 Microsoft 账户的公共客户端，启用公共客户端流，添加 Microsoft Graph 委托权限 `Files.ReadWrite.AppFolder`，不创建客户端密钥。设置该应用的客户端 ID 后，重新执行 Connect：

```powershell
$env:ONEDRIVE_IMAGE_CLIENT_ID = '你的应用客户端UUID'
pwsh.exe -NoProfile -File ./scripts/onedrive_image.ps1 -Action Connect
```

在调用工具的每个进程中保持相同环境变量。自定义应用使用独立的缓存及回执子目录，不复用默认应用的授权。自建应用需要自行验证租户策略、个人账户与设备代码流配置；默认客户端已实测，自建应用未做实时验证。

## 上传与清理

```powershell
pwsh.exe -NoProfile -File ./scripts/onedrive_image.ps1 -Action Upload -Path 'C:/images/reference.png'
```

返回 JSON，包括 `status: ready`、`receiptPath`、字节数、SHA256 和 URL 验证时间；**不会打印下载 URL**。保存 `receiptPath`，稍后可刷新或删除：

```powershell
pwsh.exe -NoProfile -File ./scripts/onedrive_image.ps1 -Action Refresh -ReceiptPath '<回执绝对路径>'
pwsh.exe -NoProfile -File ./scripts/onedrive_image.ps1 -Action Remove -ReceiptPath '<回执绝对路径>'
```

支持 PNG、JPEG、WebP、GIF，核对扩展名及文件签名，不是完整图像解码或内容安全扫描。单文件上限保守设为 250,000,000 字节，使用 Graph simple upload；这**不是 AI 接口的输入上限**。上传不静默转码或压缩。远程文件名按 SHA256 去重，同一图片会复用同一远程文件；删除前须确认所有使用它的任务已完成读取。

## 接入 AI 请求

参考 [`examples/image_input.py`](examples/image_input.py)。调用程序私下捕获 `-Action Url -ReceiptPath ... -RevealUrl` 的标准输出，获取新 URL，并立即放入实际接口支持的图片字段。**不要在聊天终端直接运行 RevealUrl，也不要运行 Python 授权助手的 token 命令**，它们会输出带访问能力的数据。

下面只构造 Chat Completions 的请求体，不会发送或产生生图费用：

```python
from examples.image_input import upload_image_part

image_part, receipt_path = upload_image_part('C:/images/reference.png')
body = {
    'model': 'YOUR_IMAGE_CAPABLE_MODEL',
    'messages': [{
        'role': 'user',
        'content': [
            {'type': 'text', 'text': 'Describe this image.'},
            image_part,
        ],
    }],
}
# Submit body privately using your provider's documented client.
# Never print/log body or image_part; they contain a signed URL.
```

Responses API 或生图接口可能使用不同的输入字段，不能直接套用此结构。URL 应放在接口定义的图片输入字段里，不是仅作为提示词正文。还要确认客户端不会下载图片再重新编码成 Base64。

临时下载 URL 的有效期由微软决定，不保证固定小时数。提交前刷新；长时间排队的异步任务可能需要改用服务商认可的持久存储或文件上传接口。已提交给远端的旧 URL 不能靠本地刷新自动更新，重提任务应遵循服务商的幂等和计费规则。

## DeepSeek 能复用吗

上传与 URL 管理不依赖特定模型，**可以复用这层能力，但必须验证实际模型和服务商支持远程图片输入**。纯文本模型不会因为收到一个 URL 就获得视觉能力。

如果 DeepSeek 用作主模型、另一个接口负责生图，则在真正的生图调用里接入本工具，给主模型传简短结果或文件信息即可。另有代理负责移除历史 Base64 图片时，两者是互补方案：本工具不裁剪历史消息，也不修改代理路由。当前没有宣称完成 DeepSeek 端到端验证。

## 不能保证解决的情况

- 请求体被历史消息、工具输出、大量文本或旧 Base64 撑大。本工具不重写已经存在的对话历史。
- AI 服务限制下载后的文件大小、像素数、图片数量或格式，或无法访问 OneDrive 域名。
- SDK、中转网关把远程 URL 重新嵌回 Base64，或根本不接受图片 URL。
- URL 已过期、远端任务排队过久，或服务商禁止重定向。

遇到 413 应定位拒绝请求的那一层，测量实际序列化请求体大小和图片数量；不要无限重试同一大请求。传 URL 减少的是请求体，不会把大图变成小图，也不会解除服务端限制。

## 安全与数据位置

默认运行数据在 `%LOCALAPPDATA%/Codex/onedrive-image-upload`，不写进代码仓库。自定义应用位于其 `clients/<client-id>` 子目录。

- MSAL token 缓存和待完成设备登录使用当前 Windows 用户 DPAPI 加密。
- 回执中的下载 URL 使用当前 Windows 用户 DPAPI 加密；回执仍含文件标识、哈希等元数据，不要公开。
- 不创建永久匿名共享权限；临时 URL 仍是免登录访问凭据，不要粘贴到 Issue、聊天或日志。
- 只上传明确选中的任务图片；不要将客户证据、身份证件或其他隐私材料作为演示素材。
- 错误仅输出非敏感状态和错误类型，不打印 Graph 原始响应。`Remove` 校验应用文件夹、文件名及大小后才删除。

DPAPI 不隔离同一 Windows 用户下的恶意进程。删除本地缓存只能退出此工具，不能撤销微软授权或删除已上传的图片；如需撤销授权，应在微软账户管理页处理。清理远端图片要先用对应回执 Remove，不要先丢失回执。

## 测试

离线测试不需要微软账户，也不会上传或调用 AI：

```powershell
python -m unittest discover -s tests -v
pwsh.exe -NoProfile -File ./scripts/test_onedrive_image.ps1
```

若依赖只装在 `.venv`，将第一条命令的 `python` 换成 `./.venv/Scripts/python.exe`。GitHub Actions 在 Windows 上使用 Python 3.11 和 3.13 运行离线测试，不需要仓库 Secrets。

已授权的本机可手动运行真实测试：

```powershell
pwsh.exe -NoProfile -File ./scripts/test_live_onedrive.ps1
```

该测试生成小型随机标记图片，真实上传，跨进程刷新链接，免登录下载并核对完整 SHA256，然后删除远程测试文件并确认 404。测试记录只保留本地；如果清理失败会明确报错，不把缓存存在当作上传成功。请勿把真实测试接入无人授权的公共 CI。

## 许可

[MIT](LICENSE)。本项目不隶属于 Microsoft、OpenAI 或 DeepSeek；不包含任何用户的授权、图片、回执或 API 密钥。
