# SprayGo v15 · 发现问题图鉴核查及云端验收单（2026-11-23）

本变更不改配方计算、喷药记录和 StoreGo。已在独立分支上修改 `OPR/SprayGo.html`，正式 main 尚未更新。

## 1. 实际源码事实
- 正式页面：`OPR/SprayGo.html`（打开时标题为 SprayGo v15）。
- 正式数据：Azura Supabase ref `dittqalvrjiamzdzrskd`，`store_doc` 的 `sg16_finding`、`sg16_dximg`；现场照片为私有 `storego-receipts/finding/...` Storage。
- 已有「发现问题」入口、23 张诊断卡、21 条案例说明、保存发现记录、查看照片、状态变更。
- 因当前 ChatGPT 的 Supabase 连接**只列出 Academee 项目，不含 Azura 项目**，本次**不能声称**已经用真实登录完成数据库和私有图片的端到端读写验收。禁止使用 Academee 数据库替代。

## 2. 本轮已实现的代码修正
1. 为全部 23 张诊断卡提供外部农业科研机构的参考文献入口；来源帮助核查症状描述，**不构成逐张 AI 图片的专业验证**。
2. 霜霉、白锈由“长茄病害”降为“叶背异常待鉴别”，撤下其 AI 示意图片，禁止自动匹配药。
3. “果身巧克力色水渍斑”仍是症状、不是已确诊病名；不按症状自动匹配药。
4. 第 1 张真实案例：红色小虫不能按“红蜘蛛”直接归类，改为小甲虫／益害虫待分辨。
5. 第 17 张真实案例：断枝／茎部纵裂图片不能当成青枯病证据，改为茎部受损待查。
6. 病毒性花叶不笼统宣称由所有白粉虱／蓟马传播；不同病毒途径不同，需先确定。
7. 发现记录云端写入后立即执行一次按 ID 的只读校验；无确认结果则明确显示失败，不声称成功。
8. 经 JavaScript 语法解析检查，未发现新语法错误。仍须在正式认证环境测试 UI、权限和照片。

## 3. 教学图片实际像素抽查（GitHub main，2026-11-23）

当前图片资产并非可以放心放大培训的高分辨率微距原照：

| 现有文件 | 原始像素 | 结论 |
|---|---:|---|
| `spraygo_dx/thrips_1.jpg` | 205 × 139 | 低清 AI 示意 |
| `spraygo_dx/whitefly_1.jpg` | 205 × 141 | 低清 AI 示意 |
| `spraygo_dx/broadmite_1.jpg` | 232 × 148 | 低清 AI 示意 |
| `spraygo_dx/leafspot_1.jpg` | 278 × 169 | 低清 AI 示意 |
| `spraygo_dx/virus_1.jpg` | 232 × 144 | 低清 AI 示意 |
| `spraygo_dx/mechanical_1.jpg` | 232 × 140 | 低清 AI 示意 |
| `spraygo_dx/guide.jpg` | 1055 × 1491 | 导览海报，可保留为导览，非单卡微距证据 |

以上是实际读取 GitHub JPEG 源文件得出的尺寸，不是估计。**必须先有独立可信的高分辨率参考图、来源和许可，才能宣称“专业高清图鉴”完成。**

## 4. 图片核验规则
- **AI 生成示意**：全部保持“示意图”标签，不能改成“真实确诊照片”。
- **实拍巡园 21 张**：可保持“真实照片／初步判断”，不能自行升级成确诊病例。
- **可信科研原图**：一张一张核对摄影来源、拍摄作物、害虫形态或病原、授权；入库前保存出处/作者/日期/许可/确认人。
- 未完成逐图科学及许可核验的项目不应以“已经专业核验”的身份培训工人。现有 `spraygo_dx/*.jpg` 为说明性图片，尚不满足这一标准。
- 例外：用户自己的田间照片，来源清楚但仍须由农技人员或实验室确认不确定的病原身份。

### 关键农业来源
- UC IPM Eggplant: https://ipm.ucanr.edu/agriculture/eggplant/
- UC IPM Whitefly: https://ipm.ucanr.edu/agriculture/eggplant/silverleaf-whitefly/
- UC IPM Mosaic potyviruses: https://ipm.ucanr.edu/agriculture/eggplant/Mosaic-Diseases-Caused-by-Potyviruses/
- UC IPM Tobacco mosaic, mechanical transmission: https://ipm.ucanr.edu/agriculture/eggplant/tobacco-mosaic/
- University of Florida, bacterial wilt/Phomopsis/Phytophthora: https://ask.ifas.ufl.edu/publication/PG047
- University of Minnesota, eggplant distorted leaves: https://apps.extension.umn.edu/garden/diagnose/plant/vegetable/eggplant/leavesdistorted.html
- World Vegetable Center, beneficial and harmful insects: https://www.gov.uk/research-for-development-outputs/a-farmer-s-guide-to-harmful-and-helpful-insects-in-eggplant-fields
- Jabatan Pertanian Malaysia registered pesticides and label: https://www.doa.gov.my/

## 5. Claude / Owner 合并前必须跑的真云端验收
1. 在 Azura 正式登录账号下打开「发现问题」，核对角色和权限。
2. 确认图鉴卡 23 张，原有 21 例能读取原图。若尚未上传，不得显示“全部已上传”。
3. 选择 AD1，一条测试发现填写区块、照片、疑似问题、状态，保存。新版本必须复核服务器上 ID 可读取。
4. 用另一台已经授权的设备重新登录并读取该记录与照片。
5. 检查“待确认→已确认→撤回”的读写流程及审计。未授权账号不得读到内部巡园图片。
6. 测试图片上传失败、断网、数据库拒绝、Storage 拒绝、无权限的明确提示。
7. 检查与 StoreGo/spray mixes/history 等已有功能的回归。
8. 对 23 个图鉴原图逐一验收真实生物学形态、出处、授权；没有通过的仍显示“示意／待验证”。

## 6. 不能宣称已完成
- 本次不是农艺师签字确认，不是病原实验室检测。
- 当前插件无法访问 Azura Supabase 项目，故无法替用户完成真实在线数据库核验，也无法为其代上传 21 张私有原图。
- 当地喷药推荐必须查马来西亚正式登记、具体产品标签、抗药性组和 PHI；不能照 AI 海报的药名直接喷。

- 2026-11-23 实际尝试用当前 Supabase 连接查询 Azura 项目：返回“**You do not have permission to perform this action**”。这确认了权限不足，不只是没看见项目列表。
