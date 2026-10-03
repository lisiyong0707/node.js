# vless-ws.js 零基础部署说明

本文面向完全没接触过服务器的新手，讲解如何把 `vless-ws.js` 部署到**带 Node.js 面板的虚拟主机或容器**上。

> **使用前请先确认**：很多免费主机的服务条款禁止运行代理服务，违规可能导致账号被停。请先阅读你所用平台的条款，风险由使用者自行承担。本文不涉及任何规避平台检测或保活的方法。
> **一键脚本**：
> ```
> wget -N https://raw.githubusercontent.com/lisiyong0707/node.js/main/deploy.sh && \
APP_URL=https://raw.githubusercontent.com/lisiyong0707/node.js/main/app.js \
UUID=你的uuid PORT=可用端口 DOMAIN=你的域名 bash deploy.sh
> ```
> 

---

## 一、先了解几个名词

| 名词 | 通俗解释 |
|---|---|
| Node.js | 运行 `.js` 程序的环境，主机面板里一般自带 |
| 环境变量 | 给程序传参数的地方，比如密码、域名，不用改代码 |
| UUID | 一串随机字符，在这里相当于"连接密码" |
| 域名 | 你的网址，如 `example.com`，需要先指向你的主机 |
| Cloudflare（CF） | 免费的域名解析和加速服务，可以顺便提供 HTTPS |
| WebSocket | 一种网络连接方式，节点就是靠它传数据 |
| 客户端 | 你手机或电脑上用来连接节点的软件 |

---

## 二、整体流程

```
准备域名 → 准备文件 → 生成密码 → 创建应用 → 上传文件
→ 填环境变量 → 安装依赖 → 启动 → 验证 → 导入客户端
```

---

## 三、准备工作

### 1. 域名

你需要一个自己的域名，并把它的 **A 记录**指向你的主机 IP。如果用 Cloudflare：

1. 把域名托管到 Cloudflare。
2. 添加 A 记录，指向主机 IP，并**打开橙色云朵**（代理）。
3. 进入 Network 页面，确认 **WebSockets 为开启**。
4. 进入 SSL/TLS 页面，加密模式先选 **Flexible**（如果主机自己提供了 HTTPS 证书，则按主机实际情况选 Full）。

### 2. 需要的文件

在电脑上新建一个文件夹，放两个文件：

**文件一：`vless-ws.js`**
这是主程序，使用我提供给你的那份。

**文件二：`package.json`**
新建文本文件，命名为 `package.json`，内容如下：

```json
{
  "name": "site",
  "version": "1.0.0",
  "main": "vless-ws.js",
  "scripts": { "start": "node vless-ws.js" },
  "dependencies": { "ws": "^8.14.2" }
}
```

> 注意：`ws` 必须是 8 版本。文件名不要多出 `.txt` 后缀。

### 3. 生成三个"随机值"

你需要：一个 UUID、一个 WS 路径、一个订阅路径。

**方法一**：如果你电脑装了 Node.js，在终端运行：

```bash
node -e "console.log(require('crypto').randomUUID())"
node -e "console.log(require('crypto').randomBytes(8).toString('hex'))"
node -e "console.log(require('crypto').randomBytes(12).toString('hex'))"
```

三行输出依次作为：UUID、WS 路径用的随机串、订阅路径。

**方法二**：搜索"UUID 生成器"的在线工具，生成一个 UUID。随机串可以自己随意敲 12 位以上的字母数字。

请把这三个值**记在本子或备忘录里**，后面要用，也不要发给别人。

---

## 四、在主机面板里部署

不同平台的界面名称略有差别，下面以常见的 Node.js 应用面板为例，找名字相近的选项即可。

### 步骤 1：创建 Node.js 应用

- Node.js 版本：选 **18 或 20**
- 模式（Mode）：**Production**
- 应用根目录（Application root）：随便起个名，如 `vless`
- 应用网址（Application URL）：选你的域名
- 启动文件（Startup file）：**`vless-ws.js`**

保存或创建。

### 步骤 2：上传文件

在面板的**文件管理器**中，进入刚才的应用根目录，上传：

- `vless-ws.js`
- `package.json`

### 步骤 3：添加环境变量

在应用页面找到 **Environment variables**，逐个点击 **ADD VARIABLE** 添加：

| 变量名 | 填什么 | 示例 |
|---|---|---|
| `UUID` | 你生成的 UUID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `DOMAIN` | 你的域名（不带 https://） | `example.com` |
| `WS_PATH` | `/` 加随机串 | `/ws-a1b2c3d4e5f6` |
| `SUB_PATH` | 订阅路径随机串 | `9f8e7d6c5b4a3210aabbccdd` |
| `NAME` | 节点名称，任意 | `my-node` |

关于端口 `PORT`：

- 如果面板**自动提供**了 PORT，就**不要自己加**。
- 如果面板告诉你一个固定端口号，就把 `PORT` 设为那个数字。
- 如果两种都没有，程序默认使用 3000，通常需要再确认平台是否允许。

### 步骤 4：安装依赖

点击面板里的 **Run NPM Install**（或类似按钮）。如果有终端（Terminal），也可以进入应用目录，运行：

```bash
npm install
```

### 步骤 5：启动

点击 **Restart / Start**。然后打开应用的**日志**，正常情况下会看到：

```
listening on :端口号
订阅路径: /你的SUB_PATH
分享链接: vless://...
```

把这条 `vless://` 开头的分享链接复制保存下来。

---

## 五、验证是否成功

1. 用浏览器访问 `https://你的域名/`：应该看到一个名为 **Field Notes** 的博客页面，这是伪装站点，说明程序已经在运行。
2. 访问 `https://你的域名/你的SUB_PATH`：页面会显示一行 `vless://` 链接。
3. 访问 `https://你的域名/乱写一个路径`：应显示 404 页面。

三项都对，说明服务端没问题。

---

## 六、导入客户端

把前面得到的 `vless://` 链接复制，导入客户端：

| 系统 | 常见客户端 |
|---|---|
| Windows | v2rayN、Clash Verge 系 |
| Android | v2rayNG、NekoBox |
| iOS | Shadowrocket、Stash 等 |
| macOS | V2rayU、Clash Verge 系 |

导入后检查这几项是否正确：

- 协议：vless
- 端口：**443**
- 传输方式：**ws**
- TLS：**开启**
- 路径：与你的 `WS_PATH` **完全一致**
- SNI 和 Host：你的域名

连接后，到任意"查 IP"的网站，看出口 IP 是否变成了主机的 IP。

---

## 七、常见问题

| 现象 | 可能原因和做法 |
|---|---|
| 打开域名显示 500 或 503 | 看应用日志；常见原因是依赖没装好，或 PORT 格式不对 |
| 日志报找不到模块 `ws` | 重新点 NPM Install，并检查 `package.json` 是否在应用根目录 |
| 日志报 `WebSocketServer is not a constructor` | `ws` 版本太低，改成 `^8.14.2` 后重装依赖 |
| 网站正常但节点连不上 | 检查路径是否一致；Cloudflare 的 WebSockets 是否开启；平台前端是否支持 WebSocket |
| 浏览器提示重定向次数过多 | Cloudflare 的 SSL 模式与源站不匹配，试试在 Flexible 和 Full 间切换 |
| 一重启节点就失效 | 没有设置 `UUID` 环境变量，导致每次随机生成；务必固定它 |
| 用一段时间进程消失 | 平台会回收空闲进程，这是平台策略，需要自己联系平台或更换环境 |
| 端口是非标准端口，Cloudflare 连不上 | 需要在 Cloudflare 的 Origin Rules 里改写目标端口，或者使用 Cloudflare 支持的端口，具体以官方文档为准 |

---

## 八、安全小提醒

- UUID、WS 路径和订阅路径都等同于密码，**不要截图发到公开场合**。
- 日志里会打印分享链接，不要把日志外传。
- 怀疑泄露时，更换 `UUID`、`WS_PATH`、`SUB_PATH` 后重启即可，客户端同步更新链接。
- 程序默认禁止访问内网和本机地址，无特殊需要不要设置 `ALLOW_PRIVATE=1`。

---

## 九、环境变量速查

| 变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `UUID` | 建议填 | 每次随机 | 连接凭据 |
| `DOMAIN` | 填 | `example.com` | 生成分享链接用 |
| `PORT` | 视平台 | `3000` | 监听端口 |
| `WS_PATH` | 建议填 | `/ws` | WebSocket 路径 |
| `SUB_PATH` | 建议填 | 每次随机 | 订阅页路径 |
| `NAME` | 否 | `vless-node` | 节点显示名称 |
| `ALLOW_PRIVATE` | 否 | 不允许 | 设为 `1` 才允许访问内网 |
