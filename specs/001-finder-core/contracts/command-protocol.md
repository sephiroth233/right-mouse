# V1 扩展与宿主命令协议

将 Finder 操作表达为可校验、可去重、可回执的消息；通信实现可替换，执行语义不得暗中改变。

协议版本：1；状态：语义基线，App Group/唤醒运输层待 G0；读者：扩展、宿主、测试开发者。

## 目录

- [1. 消息与命令](#1-消息与命令)
- [2. 运输机制和信任边界](#2-运输机制和信任边界)
- [3. 校验和错误](#3-校验和错误)
- [4. 回执、超时与重试](#4-回执超时与重试)
- [5. 示例与兼容](#5-示例与兼容)
- [参考](#参考)

## 1. 消息与命令

请求结构见 [request.schema.json](request.schema.json)，采用 JSON Schema Draft 2020-12。顶层包含版本、requestID、producerInstanceID、createdAt、expiresAt、context 和 action；禁止未声明字段。时间为带时区的 RFC 3339，ID 为 UUID。Schema 约束结构，接收器仍必须校验时间、路径、动作上下文、资源和权限。

| action.type | 参数 | 行为与来源 |
| --- | --- | --- |
| createFile | templateID、destination、可选 name | 用目标目录与模板创建；不以工作目录兜底 |
| copyText | format: path/name/stem/shellPath | 读取 context.selection；无选择时仅 path/shellPath 可用 container |
| stageMove | 无额外参数 | 将 context.selection 交给宿主剪切列表 |
| pasteMove | pendingToken、destination、conflictPolicy | 使用宿主活动剪切列表，不能由调用者指定任意 token 来恢复旧操作 |
| transfer | mode: copy/move、destination、conflictPolicy | 来源为非空 context.selection |
| openFavorite | favoriteID | 在 Finder 打开宿主已保存的收藏 |
| openWith | integrationID、mode: files/directory | files 用选中项；directory 使用规格规定的唯一目录或提示选择 |

`conflictPolicy` 只允许 ask、skip、keepBoth。配置编辑、取消、冲突选择和恢复由宿主 UI 直接调用内部服务，V1 不开放为外部唤醒命令。UUID 型文件引用 ID 只用于关联，不授予访问权。

施工澄清（2026-09-22）：createFile、pasteMove、transfer 的 destination 字段仍必须存在，但允许显式 null，表示由宿主展示目录选择器；取消选择不产生文件变更。这样能够实现 FR-007 的“选择目录”和跨目录多选交互，不使用伪造路径。非空 destination 的 kindHint 为 unknown 时，宿主根据实际选中对象解析目录，不能仅用 URL 尾部斜杠判断。

## 2. 运输机制和信任边界

发布路径：共享容器 `Inbox/<requestID>.tmp` 写完并关闭，再在同目录无覆盖提交为 `<requestID>.json`。不同扩展实例使用不同 producerInstanceID。请求入队后显式唤醒已知宿主，传递 `rightmouse://dispatch/<requestID>`；宿主校验 scheme/host/path 且拒绝 query/fragment，不从 URL 接收 action 或文件路径。

宿主从受控容器读取实际请求，确认文件名与内容 ID 一致、普通文件而非符号链接、权限/所有权符合容器策略、体积合法。requestID 防止混淆，不是认证秘密。共享容器和签名策略在 G0 验证；本协议不声称能抵抗已完全控制同一用户账号的恶意进程。

获取宿主单执行器锁后，验证并持久记录 accepted，随后才允许副作用。收到相同 ID 且规范化内容摘要一致时返回旧回执；相同 ID 不同内容返回 REQUEST_ID_CONFLICT。规范化通过解析后的强类型字段、固定键序列/编码实现，测试覆盖 JSON 空白与键顺序变化；不得仅比较原始 JSON 字节。

创建/修改文件的全部路径均由 FileReference 解析、权限检查和规划结果提供。模板/收藏/应用 ID 从宿主配置查找。任何 token 都不可直接作为磁盘相对路径拼接。URL 唤醒但找不到已提交请求，只产生诊断，不创建操作。

## 3. 校验和错误

依次检查：原始字节 <= 1 MiB → JSON/Schema → UUID 和日期格式 → 白名单语义 → 已接受请求去重 → 新请求时间窗口 → 权限/身份/动作前置条件。对已接受且同内容请求返回旧回执，即使其已过期；同 ID 不同内容拒绝。只有去重索引中不存在的请求才进入新请求时效检查，不能因此接受未知过期请求。

TTL 最大 120 秒，createdAt 不得比宿主时钟未来超过 30 秒，expiresAt 必须晚于 createdAt。selected refs 的 refID 不能重复；fileURL 必须是本地 `file:` URL，禁止非空远程 host、query、fragment、NUL 和无效百分号编码。解码和路径标准化不得意外追踪源符号链接；目标祖先关系在执行阶段按实际目录身份检查。

| 错误码 | 语义 | 恢复方式 |
| --- | --- | --- |
| INVALID_REQUEST / UNSUPPORTED_VERSION | 结构、动作或协议不支持 | 不执行；升级组件或修复生产者 |
| REQUEST_EXPIRED / REQUEST_ID_CONFLICT | 过期或 ID 被不同内容复用 | 用户重新触发；冲突记录诊断 |
| CONTEXT_UNAVAILABLE / LIMIT_EXCEEDED | 没有有效目标、选择/体积超限 | 选择目录或分批 |
| ACCESS_DENIED / BOOKMARK_STALE | 无访问权或持久引用失效 | 宿主按具体目录授权或修复 |
| SOURCE_MISSING / SOURCE_CHANGED | 来源消失或身份/内容变化 | 保留现场，重新选择 |
| DESTINATION_CONFLICT / INVALID_DESTINATION | 目标重名、自身后代、非法类型 | 询问、保留两份或跳过 |
| NO_SPACE / VOLUME_UNAVAILABLE | 空间不足或卷不在 | 保留源，连接/释放空间后重试失败项 |
| APP_UNAVAILABLE / AUTOMATION_DENIED | 应用不存在或适配权限被拒 | 安装/重选应用或调整授权 |
| IO_FAILED / METADATA_UNSUPPORTED | 普通 I/O 或必要元数据不兼容 | 记录逐项结果；移动不得静默清除源 |
| SOURCE_RETAINED / RECOVERY_REQUIRED | 目标可能已完成，源保留或状态未确定 | 用户核对；禁止自动新请求重跑 |
| CANCELLED | 用户取消未开始/可取消阶段 | 保留已完成项的真实状态 |

操作系统底层错误可保存 domain/code，但展示文案和调试日志不泄露文件内容或书签。未识别底层错误映射 IO_FAILED，不吞异常。

## 4. 回执、超时与重试

回执结构见 [response.schema.json](response.schema.json)，包含 requestID、revision、status、updatedAt、itemResults、error。写入顺序受 [数据状态机](../data-model.md) 约束，revision 单调递增，界面忽略旧 revision。itemResults 按顶层项目返回 itemID、status、destinationURL? 和 error?；包含路径的完整回执仅保留在用户私有容器，不进入公开日志。

10 秒无 accepted 回执，UI 提示等待并允许用户查看诊断；禁止认定未执行或自动生成新请求。可以用同 ID 重发同内容以唤醒/查询，接收端去重。结果为 partial/failed 时，用户选择具体失败项才生成新 ID，宿主日志保存 retryOf；状态未知先核对，不进行自动重试。

到期只影响入队接受，不取消正在执行的操作。任务等待用户期间不持有源删除的授权决定：恢复执行需要复核来源和目标。命令回执是本应用已知状态，不提供跨文件系统 exactly-once 保证；“意图已写但结果未写”的场景进入恢复判断。

## 5. 示例与兼容

有效结构示例在 [examples/create-file.json](examples/create-file.json)。其中时间和路径是固定测试数据，不能直接投到真实运行中的队列；运行时必须重新生成时间、UUID 和经用户上下文获取的文件引用。

负例 `examples/invalid-command.json` 必须被 Schema 拒绝。语义负例（已过期、目标是来源后代、同 ID 内容冲突）可能在 Schema 层通过，但接收器必须拒绝，具体用例为 AC-025 和 AC-026。后续测试不得把结构验证等同于权限验证。

未知 schemaVersion 直接拒绝。字段增加或动作语义变化先升级协议并补兼容测试；扩展和宿主版本不一致时返回可读诊断。运输层替换为 XPC 时另补调用者身份验证，JSON 结构测试和业务用例保持有效。

## 参考

- [JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12)
- [需求规格](../spec.md)
- [Apple App Group 与 Finder Sync](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)
