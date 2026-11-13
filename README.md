# ReFlex

基于随附的 FLEX++ 1.0.3 汉化源码。首版聚焦 UIKit 页面排查。

## 页面导出

打开 FLEX 后进入「菜单 → 页面与调试 → 导出当前页面」，在系统分享面板保存 reflex-page.json。导出从宿主窗口的根控制器开始，沿当前模态页面、导航栈可见页面或选中的标签页定位，然后递归记录该控制器根视图下的控件。

JSON 包含 schemaVersion、bundleIdentifier、controllerClass、rootView。每个控件节点有 class、frame（父视图坐标，单位为点）、hidden（控件自己的隐藏状态）和 children。数据范围为 UIKit 视图结构。自定义容器会以其根视图为边界，WebView 的 DOM 不在 UIKit 树中。

全局菜单保留系统日志、运行时类浏览、主窗口、根控制器和容器浏览，以及原有的浮条选取和层级查看。Dylix AI 联动模块已从构建源码中移除。

## 局域网 MCP

电脑和手机连接到能互通的同一局域网。电脑端使用 Python 3.11 或以上版本，在仓库根目录运行：

    python -m pip install -r mcp/requirements.txt
    python -c "import secrets; print(secrets.token_hex(16))"

用支持本地 stdio 的 MCP 客户端启动脚本。以下为采用 mcpServers 格式的示例，替换 Python 路径、脚本路径、电脑的 Wi-Fi IPv4 和生成的配对码：

    {
      "mcpServers": {
        "reflex": {
          "command": "C:/path/to/python.exe",
          "args": ["C:/path/to/ReFlex/mcp/server.py", "--listen", "192.168.1.10", "--port", "8765", "--token", "<配对码>"]
        }
      }
    }

在手机上进入「菜单 → 页面与调试 → 局域网 MCP」，填写地址、端口和配对码，然后点「开启会话」。设置会保存。调试结束后回到同一入口点「关闭会话」。宿主 App 在前台且会话开启时，手机每秒查询电脑是否有待处理请求，收到请求后才采集页面。

- `read_page_snapshot` 每次调用都获取手机此刻的控制器类名和 UIKit 控件树。使用 FLEX 选中当前页面内的控件后，结果还会包含 `selectedView`，其中有类名、从根节点起的子视图索引、窗口坐标，以及可用的按钮标题和点击事件方法名。
- `inspect_controller_runtime` 也会刷新页面，返回当前控制器类自身的方法选择器。`query` 可按名称片段筛选。

换页后让 AI 再读取一次即可。手机关闭会话、宿主 App 退到后台或连接失败时，电脑等待约 8 秒后返回错误。

手机到电脑使用带配对码的 HTTP，数据在局域网中明文传输，适合可信网络。电脑只在指定的私有 IPv4 上监听。若连接失败，检查 Windows 防火墙是否放行专用网络上的端口，以及手机宿主 App 的局域网权限和 ATS 配置。允许对指定地址发起 HTTP 连接的配置由宿主 App 决定。[Apple 局域网权限说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) · [Apple ATS 地址例外](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)

离线导出仍可使用。启动脚本时以 JSON 文件路径作为唯一参数，即切换到文件读取模式。[MCP Python SDK 1.x](https://py.sdk.modelcontextprotocol.io/v1/)

## 云编译

GitHub Actions 的 Build ReFlex 工作流在推送到 main 时执行，也支持手动运行。下载名为 ReFlex 的产物，里面有一份独立的 ReFlex.dylib 和三个对应安装环境的 deb。

| 文件 | 环境 |
| --- | --- |
| ReFlex.dylib | 单份通用库，含 ARMv7（32 位 ARM）、arm64 和 arm64e 切片 |
| ReFlex_1.0.3_rootful.deb | Rootful |
| ReFlex_1.0.3_rootless.deb | Rootless |
| ReFlex_1.0.3_roothide.deb | RootHide |

三个 deb 各自包含注入过滤 plist，并复用同一份 dylib。CI 会校验切片和签名，检查系统库依赖，再从每个 deb 解包并逐字节比对 dylib。

工作流使用 Xcode 16.4 和 Theos 的 iOS 15.6 SDK，arm64e 切片按 iOS 14 及以上的 ABI 构建。架构切片通过检查只证明文件包含对应的机器码。老系统上的功能兼容性和三种环境下的加载仍需实机验证。[Theos arm64e 说明](https://theos.dev/docs/arm64e-deployment)

本地单架构调试可继续用 Theos。在 FLEX-1.0.3-source/Plugins/FLEX 执行：

    LC_ALL=C LANG=C make stage FINALPACKAGE=1 DEBUG=0 -j1

安装包沿用原包标识，包管理器会将其视为同一软件包。
