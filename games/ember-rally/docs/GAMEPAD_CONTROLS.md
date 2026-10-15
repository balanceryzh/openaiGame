# 原生手柄输入与验证

本增量为 Godot 原生 InputMap 输入，不是把手柄转换成键盘按键。键鼠仍可随时使用，界面提示跟随最近使用的输入方式切换。

## 操作

下表采用 Xbox 字母。标准映射的 PlayStation 手柄对应：A = 下方面键 Cross，B = 右方面键 Circle，X = 左方面键 Square，Y = 上方面键 Triangle，RB = R1，Start = Options，View/Back = Share。其他手柄依 Godot 识别的标准位置映射；没有针对每一种硬件实测。

| 功能 | 键鼠 | 手柄 |
| --- | --- | --- |
| 移动 | WASD / 方向键 | 左摇杆 / 十字键 |
| 标题开始 | Enter / 点击 | A / Start |
| 普通攻击 | 自动挥刀 | 自动挥刀 |
| 圣闪 | Q | X / RB |
| 暂停 / 继续 | Esc；暂停时 Enter 也可继续 | Start / B；暂停时 A 也可继续 |
| 行军图 | Tab | View / Back |
| 从行军图返回 | Tab / Esc | View / B / Start |
| 升级导航 | 左右 / A、D | 左摇杆左右 / 十字键左右 |
| 确认高亮升级 | Enter | A |
| 直接选择升级 | 1 / 2 / 3；点击相应卡片 | 先导航后 A |
| 暂停时重新开始 | R | Y |
| 胜负后重新开始 | R / Enter / 点击 | A / Y |
| 音量与静音 | 原有 M、- / =、[ / ] 保留 | 未新增音频调节绑定 |

从暂停界面打开行军图，再返回时仍处于暂停。升级必须选择一项强化，B / Start 不会跳过强化或解除战斗暂停。圣闪输入仅在战斗进行时调用派生战斗逻辑的 `cast_holy_flash()`；技能效果、冷却和消耗由该方法负责。

## 模拟摇杆与升级导航

- 移动为 0.22 圆形死区；死区以外的幅度线性重映射，斜向速度不超过直向
- 左摇杆 0.61 输入得到约 0.5 移动强度，最高移动速度仍为 205 逻辑像素 / 秒
- 面向与队伍跟随方向保持单位向量，位移保留模拟强度
- 菜单导航按下阈值 0.55，回中阈值 0.30；首次连发等待 0.32 秒，之后每 0.14 秒一步
- 升级卡片有金色选中边框与 A / Enter 确认提示，左右循环三项
- 行走时按住摇杆进入升级，需先回中再导航，防止移动输入意外改变强化选择
- 输入映射匹配任意标准手柄设备编号；手柄轻微漂移不会切换键鼠提示

## 验证结果

Godot 4.6.3 无界面测试：`large/qa/test_gamepad_input.gd`，67 项通过，0 项失败。

测试以 `Input.parse_input_event()` 注入真正的 Godot 摇杆、十字键、按钮、键盘和鼠标事件，经过 InputMap 和场景输入分发；不是直接伪造键盘状态。

覆盖：

- 模拟死区、半速、满速、斜向限速、十字键、WASD、非零设备编号和释放归零
- 标题开始、暂停/继续/返回、行军图返回位置、胜负重开与键盘重复键防护
- 升级选中项、循环、连发延时、噪声防护、强制回中、确认和不可绕过的暂停
- 圣闪 Q / X / RB 调用与所有非战斗状态的禁用
- 鼠标开始、重开、升级；卡片间隙与外侧点击不会误选
- 键鼠/手柄提示切换及生产字体的文字宽度检查
- 实际 `battle_logic.gd` 中 50 毫秒移动：半速 5.125 px、满速 10.25 px；真实音频暂停、游戏时钟与尸源冻结；真实 XP 升级与恢复

可复现命令（项目根目录）：

```sh
mkdir -p /tmp/battlefield-gamepad-home/{.config,.cache,.local/share}
HOME=/tmp/battlefield-gamepad-home \
XDG_CONFIG_HOME=/tmp/battlefield-gamepad-home/.config \
XDG_CACHE_HOME=/tmp/battlefield-gamepad-home/.cache \
XDG_DATA_HOME=/tmp/battlefield-gamepad-home/.local/share \
godot --headless --path . --script large/qa/test_gamepad_input.gd
```

结果：`large/qa/gamepad_input_results.json`；完整日志：`large/qa/gamepad_input_tests.log`。

补充检查：原身体避让测试 8 项通过。旧 `test_large_scene.gd` 为 40 项通过、3 项失败；相同 3 项在本增量前已出现，分别是旧版“全部桥始终开放”和两项旧版 0.8 秒死亡精灵假设，当前工程已采用吊桥与消散规则。其暂停、地图、升级与场景时钟检查通过。其他历史测试仍包含旧营门触发首领/死灵法师出生约束，不据此宣称全部历史测试通过。

## 验收边界

本环境没有实体手柄，也无法启动本地图形窗口。以上是合成输入与真实逻辑集成测试，不代表已在 USB / 蓝牙、Xbox / PlayStation / Switch 硬件上实玩通过。选中边框已实现，文字宽度已计算，但此次未取得原生窗口截图。交付后的实机验收应确认连接/拔插、按键位置、慢推摇杆、暂停返回、升级选中边框与圣闪显示。
